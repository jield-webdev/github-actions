require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

# Execute the actual inline workflow scripts against temporary files and repos.
# No network calls, Writerside builds, or Pages deployments are involved.
class WritersidePagesTest < Minitest::Test
  WORKFLOW = YAML.load_file(File.expand_path('../.github/workflows/writerside-pages.yml', __dir__))
  SHA = '1234567890abcdef1234567890abcdef12345678'.freeze

  def setup
    @work = Dir.mktmpdir('writerside-pages-')
    @env = {
      'INSTANCE' => 'docs/guide',
      'CURRENT_BRANCH' => 'main',
      'DEVELOP_BRANCH' => 'develop',
      'CONTENT_BRANCH' => 'gh-pages',
      'SITE_URL' => 'https://example.github.io/project',
      'CUSTOM_DOMAIN' => '',
      'EVENT_NAME' => 'push',
      'REF' => 'refs/heads/main',
      'REF_NAME' => 'main',
      'COMMIT_SHA' => SHA,
      'MANUAL_RELEASE_REF' => '',
      'GITHUB_OUTPUT' => File.join(@work, 'outputs'),
      'ROOT_ID' => 'main',
      'ROOT_VERSION' => '2.0.0',
      'RELEASE_ID' => '',
      'RELEASE_VERSION' => '',
      'RELEASE_LABEL' => '',
      'GIT_CONFIG_GLOBAL' => File::NULL,
      'GIT_CONFIG_NOSYSTEM' => '1'
    }
    install_portable_tools
  end

  def teardown
    FileUtils.remove_entry(@work)
  end

  def test_pull_request_only_checks_the_pr_commit
    outputs = select_versions('EVENT_NAME' => 'pull_request', 'REF' => 'refs/pull/12/merge')
    assert_equal 'false', outputs.fetch('deploy')
    assert_equal [{ 'id' => 'check', 'ref' => SHA, 'channel' => 'check', 'version' => '' }], matrix(outputs)
  end

  def test_current_and_develop_pushes_pin_the_triggering_commit
    %w[main develop].each do |branch|
      outputs = select_versions('REF' => "refs/heads/#{branch}", 'REF_NAME' => branch)
      assert_equal 'true', outputs.fetch('deploy')
      assert_equal 'main', outputs.fetch('root_id')
      assert_equal SHA, matrix(outputs).find { |entry| entry['id'] == branch }.fetch('ref')
      other_branch = branch == 'main' ? 'develop' : 'main'
      assert_equal other_branch, matrix(outputs).find { |entry| entry['id'] == other_branch }.fetch('ref')
    end
  end

  def test_release_branches_create_previews
    %w[2.1 2.1.3 2.1.3-rc.1].each do |version|
      outputs = select_versions('REF' => "refs/heads/release/#{version}", 'REF_NAME' => "release/#{version}")
      assert_equal "#{version} Preview", outputs.fetch('release_label')
      assert_equal "release-#{version}", outputs.fetch('release_id')
      assert_equal({ 'id' => "release-#{version}", 'ref' => SHA, 'channel' => 'release-preview', 'version' => version }, matrix(outputs).last)
    end
  end

  def test_release_tags_publish_and_archive_the_same_commit
    outputs = select_versions('REF' => 'refs/tags/v2.1.3', 'REF_NAME' => 'v2.1.3')
    assert_equal '2.1.3', outputs.fetch('root_version')
    assert_equal 'current-2.1.3', outputs.fetch('root_id')
    assert_equal '2.1.3', outputs.fetch('release_label')
    assert_equal %w[develop current release], matrix(outputs).map { |entry| entry.fetch('channel') }
    assert_equal [SHA, SHA], matrix(outputs).drop(1).map { |entry| entry.fetch('ref') }
  end

  def test_manual_release_rebuild_keeps_current_and_develop_branches
    %w[v1.2.3 refs/tags/v1.2.3 v1.2.3-rc.1].each do |ref|
      outputs = select_versions('EVENT_NAME' => 'workflow_dispatch', 'MANUAL_RELEASE_REF' => ref)
      assert_equal 'main', outputs.fetch('root_id')
      assert_equal '', outputs.fetch('root_version')
      assert_equal %w[main develop], matrix(outputs).first(2).map { |entry| entry.fetch('ref') }
      assert_equal ref, matrix(outputs).last.fetch('ref')
    end
  end

  def test_configured_source_branches_are_used_for_push_tag_and_manual_runs
    branches = { 'CURRENT_BRANCH' => 'trunk', 'DEVELOP_BRANCH' => 'next' }
    outputs = select_versions(branches.merge('REF' => 'refs/heads/trunk', 'REF_NAME' => 'trunk'))
    assert_equal [SHA, 'next'], matrix(outputs).map { |entry| entry.fetch('ref') }

    outputs = select_versions(branches.merge('REF' => 'refs/tags/v2.0.0', 'REF_NAME' => 'v2.0.0'))
    assert_equal 'next', matrix(outputs).first.fetch('ref')

    outputs = select_versions(branches.merge('EVENT_NAME' => 'workflow_dispatch', 'MANUAL_RELEASE_REF' => 'v1.2.3'))
    assert_equal %w[trunk next v1.2.3], matrix(outputs).map { |entry| entry.fetch('ref') }
  end

  def test_manual_runs_on_other_branches_only_check
    outputs = select_versions('EVENT_NAME' => 'workflow_dispatch', 'REF' => 'refs/heads/feature/docs', 'REF_NAME' => 'feature/docs')
    assert_equal 'false', outputs.fetch('deploy')
    assert_equal 'check', matrix(outputs).first.fetch('channel')
  end

  def test_invalid_release_refs_fail_before_output_is_written
    [
      { 'REF' => 'refs/tags/v../escape', 'REF_NAME' => 'v../escape' },
      { 'REF' => 'refs/heads/release/../escape', 'REF_NAME' => 'release/../escape' },
      { 'EVENT_NAME' => 'workflow_dispatch', 'MANUAL_RELEASE_REF' => 'feature/other' }
    ].each do |env|
      FileUtils.rm_f(@env.fetch('GITHUB_OUTPUT'))
      _, stderr, status = capture_step('prepare', 'Select documentation versions', env)
      refute status.success?
      assert_match(/Unsupported release/, stderr)
      refute File.exist?(@env.fetch('GITHUB_OUTPUT'))
    end
  end

  def test_channels_configure_canonical_urls_and_indexing_in_the_instance_directory
    {
      'current' => ['', 'false'],
      'develop' => ['/develop', 'true'],
      'release-preview' => ['/releases/2.0.0', 'true'],
      'release' => ['/releases/2.0.0', 'false'],
      'check' => ['', 'true']
    }.each do |channel, (suffix, noindex)|
      write_writerside_config
      run_step('build', 'Configure ', 'DOCS_CHANNEL' => channel, 'DOCS_VERSION' => '2.0.0', 'SITE_URL' => 'https://example.github.io/project/')
      profiles = read('docs/cfg/buildprofiles.xml')
      assert_includes profiles, "<web-root>https://example.github.io/project#{suffix}</web-root>"
      assert_includes profiles, '<versions-switcher>https://example.github.io/project/versions.json</versions-switcher>'
      assert_includes profiles, "<noindex-content>#{noindex}</noindex-content>"
      refute_match(/web-path=|version=|versionName=/, read('docs/writerside.cfg'))
    end
  end

  def test_existing_web_root_and_version_switcher_are_updated
    write_writerside_config('<web-root>https://old.example</web-root><versions-switcher>https://old.example/versions.json</versions-switcher>')
    run_step('build', 'Configure ', 'DOCS_CHANNEL' => 'current', 'DOCS_VERSION' => '')
    refute_includes read('docs/cfg/buildprofiles.xml'), 'old.example'
    assert_equal 1, read('docs/cfg/buildprofiles.xml').scan('<versions-switcher>').length
  end

  def test_assembly_preserves_historical_releases_and_replaces_current_builds
    prepare_site
    write_archive('release-2.0.0', 'release')
    run_step('deploy', 'Assemble versioned website', release_env.merge('CUSTOM_DOMAIN' => 'docs.example.com'))

    assert_equal 'current', read('published/index.html')
    assert_equal 'develop', read('published/develop/index.html')
    assert_equal 'release', read('published/releases/2.0.0/index.html')
    assert_equal 'old release', read('published/releases/1.0.0/index.html')
    assert_equal 'keep', read('published/.git/keep')
    refute File.exist?(File.join(@work, 'published/obsolete.html'))
    refute File.exist?(File.join(@work, 'published/develop/obsolete.html'))
    assert_equal "docs.example.com\n", read('published/CNAME')
    assert File.exist?(File.join(@work, 'published/.nojekyll'))
    assert_equal 'Current (2.0.0)', config('published').fetch('productVersion')
    assert_equal 'Develop', config('published/develop').fetch('productVersionName')
    assert_equal '2.0.0', config('published/releases/2.0.0').fetch('productVersion')
    assert_equal [
      { 'version' => 'Develop', 'url' => '/project/develop/', 'isCurrent' => false },
      { 'version' => 'Current (2.0.0)', 'url' => '/project/', 'isCurrent' => true },
      { 'version' => '2.0.0', 'url' => '/project/releases/2.0.0/', 'isCurrent' => false },
      { 'version' => '1.0.0', 'url' => '/project/releases/1.0.0/', 'isCurrent' => false }
    ], JSON.parse(read('published/versions.json'))
  end

  def test_preview_does_not_replace_an_existing_stable_release
    prepare_site
    write_release('2.0.0', 'stable release', '2.0.0')
    write_archive('release-2.0.0', 'preview')
    run_step('deploy', 'Assemble versioned website', release_env.merge('RELEASE_LABEL' => '2.0.0 Preview'))
    assert_equal 'stable release', read('published/releases/2.0.0/index.html')
    assert_equal '2.0.0', config('published/releases/2.0.0').fetch('productVersion')
  end

  def test_stable_release_replaces_its_preview
    prepare_site
    write_release('2.0.0', 'preview', '2.0.0 Preview')
    write_archive('release-2.0.0', 'stable release')
    run_step('deploy', 'Assemble versioned website', release_env)
    assert_equal 'stable release', read('published/releases/2.0.0/index.html')
    assert_equal "2.0.0\n", read('published/releases/2.0.0/.docs-version-label')
  end

  def test_custom_domain_site_has_root_relative_version_links_and_preserves_cname
    prepare_site
    run_step('deploy', 'Assemble versioned website', 'SITE_URL' => 'https://docs.example.com/')
    assert_equal "existing.example.com\n", read('published/CNAME')
    assert_equal ['/develop/', '/', '/releases/1.0.0/'], JSON.parse(read('published/versions.json')).map { |entry| entry.fetch('url') }
  end

  def test_current_label_uses_latest_tag_merged_into_the_configured_current_branch
    prepare_site
    command('git', 'init', '--bare', 'origin.git')
    command('git', 'init', '--initial-branch=trunk', 'source')
    command('git', '-C', 'source', 'config', 'user.name', 'Workflow Test')
    command('git', '-C', 'source', 'config', 'user.email', 'test@example.com')
    command('git', '-C', 'source', 'commit', '--allow-empty', '-m', 'Initial')
    command('git', '-C', 'source', 'tag', 'v1.9.0')
    command('git', '-C', 'source', 'tag', 'v1.10.0')
    command('git', '-C', 'source', 'switch', '-c', 'unmerged')
    command('git', '-C', 'source', 'commit', '--allow-empty', '-m', 'Unmerged release')
    command('git', '-C', 'source', 'tag', 'v99.0.0')
    command('git', '-C', 'source', 'switch', 'trunk')
    command('git', '-C', 'source', 'remote', 'add', 'origin', File.join(@work, 'origin.git'))
    command('git', '-C', 'source', 'push', 'origin', 'trunk', '--tags')

    run_step('deploy', 'Assemble versioned website', 'CURRENT_BRANCH' => 'trunk', 'ROOT_VERSION' => '')
    assert_equal 'Current (1.10.0)', config('published').fetch('productVersion')
  end

  private

  def script(job, name_prefix)
    WORKFLOW.fetch('jobs').fetch(job).fetch('steps').find { |step| step.fetch('name', '').start_with?(name_prefix) }.fetch('run')
  end

  def capture_step(job, name_prefix, env = {})
    Open3.capture3(@env.merge(env), 'bash', '-c', script(job, name_prefix), chdir: @work)
  end

  def run_step(job, name_prefix, env = {})
    stdout, stderr, status = capture_step(job, name_prefix, env)
    assert status.success?, "#{name_prefix} failed (#{status.exitstatus}):\n#{stdout}\n#{stderr}"
    stdout
  end

  def select_versions(env = {})
    FileUtils.rm_f(@env.fetch('GITHUB_OUTPUT'))
    run_step('prepare', 'Select documentation versions', env)
    read('outputs').lines.to_h { |line| line.chomp.split('=', 2) }
  end

  def matrix(outputs)
    JSON.parse(outputs.fetch('matrix'))
  end

  def write(path, content)
    full_path = File.join(@work, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end

  def read(path)
    File.read(File.join(@work, path))
  end

  def config(path)
    JSON.parse(read("#{path}/config.json"))
  end

  def command(*args, chdir: @work)
    stdout, stderr, status = Open3.capture3(@env, *args, chdir: chdir)
    assert status.success?, "#{args.inspect} failed:\n#{stdout}\n#{stderr}"
    stdout
  end

  def write_writerside_config(existing_variables = '')
    write('docs/writerside.cfg', '<ihp><instance src="guide.tree" web-path="old" version="old" versionName="Old"/></ihp>')
    write('docs/cfg/buildprofiles.xml', "<buildprofiles><variables>#{existing_variables}</variables><build-profile><variables><noindex-content>false</noindex-content></variables></build-profile></buildprofiles>")
  end

  def write_archive(id, page)
    build_path = "builds/#{id}"
    write("#{build_path}/index.html", page)
    write("#{build_path}/config.json", JSON.generate('productVersion' => '', 'productVersionName' => '', 'other' => 'retained'))
    archive = File.join(@work, "artifacts/docs-#{id}/webHelpGUIDE2-all.zip")
    FileUtils.mkdir_p(File.dirname(archive))
    command('zip', '-qr', archive, '.', chdir: File.join(@work, build_path))
  end

  def write_release(version, page, label)
    write("published/releases/#{version}/index.html", page)
    write("published/releases/#{version}/config.json", '{}')
    write("published/releases/#{version}/.docs-version-label", "#{label}\n")
  end

  def prepare_site
    write_archive('main', 'current')
    write_archive('develop', 'develop')
    write('published/obsolete.html', 'stale')
    write('published/develop/obsolete.html', 'stale')
    write('published/.git/keep', 'keep')
    write('published/CNAME', "existing.example.com\n")
    write_release('1.0.0', 'old release', '1.0.0')
  end

  def release_env
    { 'RELEASE_ID' => 'release-2.0.0', 'RELEASE_VERSION' => '2.0.0', 'RELEASE_LABEL' => '2.0.0' }
  end

  def install_portable_tools
    return unless RUBY_PLATFORM.include?('darwin')

    # macOS unzip lacks Ubuntu's -O encoding option; fixture names are ASCII.
    bin = File.join(@work, 'bin')
    FileUtils.mkdir_p(bin)
    unzip = File.join(bin, 'unzip')
    File.write(unzip, "#!/bin/bash\nif [[ \"$1\" == -O ]]; then shift 2; fi\nexec /usr/bin/unzip \"$@\"\n")
    FileUtils.chmod(0755, unzip)
    gsort = ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, 'gsort') }.find { |path| File.executable?(path) }
    FileUtils.ln_s(gsort, File.join(bin, 'sort')) if gsort
    @env['PATH'] = "#{bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH')}"
  end
end

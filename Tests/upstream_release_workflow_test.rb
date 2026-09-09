# 运行：ruby Tests/upstream_release_workflow_test.rb
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

class UpstreamReleaseWorkflowTest < Minitest::Test
  WORKFLOW = YAML.load_file(File.expand_path('../.github/workflows/voiceink-upstream-release.yml', __dir__))
  DISCOVER = WORKFLOW.fetch('jobs').fetch('discover').fetch('steps').first.fetch('run')

  def release(tag, date, draft: false, prerelease: false)
    {tag_name: tag, published_at: date, created_at: date, draft: draft,
     prerelease: prerelease, name: tag, body: 'Release notes'}
  end

  def discover(upstream, fork: [], requested: '')
    Dir.mktmpdir('voiceink-workflow-test') do |dir|
      File.write("#{dir}/upstream.json", JSON.generate(upstream))
      File.write("#{dir}/fork.json", JSON.generate(fork))
      File.write("#{dir}/gh", <<~'SH')
        #!/bin/bash
        set -euo pipefail
        case "${*: -1}" in
          repos/Beingpax/VoiceInk/releases*) cat "$FIXTURES/upstream.json" ;;
          repos/test/VoiceInk/releases*) cat "$FIXTURES/fork.json" ;;
          repos/Beingpax/VoiceInk/git/ref/tags/*)
            printf '{"object":{"type":"commit","sha":"0123456789012345678901234567890123456789"}}' ;;
          *) echo "Unexpected gh invocation: $*" >&2; exit 1 ;;
        esac
      SH
      File.chmod(0755, "#{dir}/gh")
      env = {'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'FIXTURES' => dir,
             'RUNNER_TEMP' => dir, 'GITHUB_OUTPUT' => "#{dir}/output",
             'REPOSITORY' => 'test/VoiceInk', 'REQUESTED_TAG' => requested}
      stdout, stderr, status = Open3.capture3(env, 'bash', '-c', DISCOVER)
      assert status.success?, "#{stdout}\n#{stderr}"
      File.read("#{dir}/output")
    end
  end

  def test_published_latest_does_not_backfill_older_releases
    latest = release('v1.72', '2026-09-02')
    output = discover([release('v1.71', '2026-09-01'), latest], fork: [latest])
    assert_includes output, "should_build=false\n"
    assert_includes output, "tag=v1.72\n"
  end

  def test_new_latest_is_built_even_when_api_order_is_unsorted
    output = discover([release('v1.71', '2026-09-01'), release('v1.73', '2026-09-03'),
                       release('v1.72', '2026-09-02')])
    assert_includes output, "should_build=true\n"
    assert_includes output, "tag=v1.73\n"
  end

  def test_explicit_older_release_remains_supported
    output = discover([release('v1.71', '2026-09-01'), release('v1.72', '2026-09-02')], requested: 'v1.71')
    assert_includes output, "should_build=true\n"
    assert_includes output, "tag=v1.71\n"
  end

  def test_no_releases_is_a_successful_noop
    assert_includes discover([]), "should_build=false\n"
  end

  def test_drafts_are_ignored
    output = discover([release('v1.72', '2026-09-02'), release('v1.73', '2026-09-03', draft: true)])
    assert_includes output, "tag=v1.72\n"
  end

  def test_prerelease_behavior_is_preserved
    output = discover([release('v1.72', '2026-09-02'), release('v1.73-beta', '2026-09-03', prerelease: true)])
    assert_includes output, "tag=v1.73-beta\n"
    assert_includes output, "prerelease=true\n"
  end

  def test_toolchain_is_selected_by_dependency_revision_not_release_tag
    step = WORKFLOW.fetch('jobs').fetch('build').fetch('steps').find do |s|
      s['name'] == 'Select the dependency-compatible toolchain'
    end
    refute step.key?('if')
    filter = step.fetch('run').match(/jq -e '(.*?)'/m)[1]
    revision = '4de9aca1d1dbdafa72f6d349b15d0009032a83f8'
    [revision, 'another-revision', nil].each do |value|
      pins = value ? [{identity: 'fluidaudio', state: {revision: value}}] : []
      _, _, status = Open3.capture3('jq', '-e', filter, stdin_data: JSON.generate(pins: pins))
      assert_equal value == revision, status.success?
    end
  end

  def test_all_workflow_shell_steps_parse
    WORKFLOW.fetch('jobs').each_value do |job|
      job.fetch('steps').each do |step|
        next unless step['run']
        _, stderr, status = Open3.capture3('bash', '-n', stdin_data: step['run'])
        assert status.success?, "#{step['name']}: #{stderr}"
      end
    end
  end
end

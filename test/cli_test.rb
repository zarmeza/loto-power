# frozen_string_literal: true

require 'json'
require 'minitest/autorun'
require 'stringio'
require 'tmpdir'

require_relative '../lib/tinaja_power/cli'
require_relative '../lib/tinaja_power/store'

# The CLI is the only part of this tool another program is meant to touch, so what matters
# here is that it exits with a usable status, prints something a human can read, and emits
# JSON a subprocess can parse.
class CLITest < Minitest::Test
  T0 = 1_760_000_000.0

  def setup
    @dir = Dir.mktmpdir('tinaja-power-cli')
    @db = "#{@dir}/power.db"
  end

  def teardown
    FileUtils.remove_entry(@dir) if File.exist?(@dir)
  end

  # Runs the CLI with the database pointed at a temp file and captures both streams.
  # --db goes after the command so that a bare `run_cli` with no arguments still reaches
  # the usage text rather than being read as a bad command name.
  def run_cli(*argv)
    args = argv.empty? ? [] : [argv.first, '--db', @db, *argv.drop(1)]
    out = StringIO.new
    err = StringIO.new
    status = TinajaPower::CLI.start(args, out:, err:)
    [status, out.string, err.string]
  end

  # Seeds a history without going through record, so a test can describe a past.
  def seed(segments)
    store = TinajaPower::Store.new(@db)
    store.seed(segments)
    store.close
  end

  def test_no_arguments_prints_the_usage_and_succeeds
    status, out, = run_cli
    assert_equal 0, status
    assert_match(/Usage: tinaja-power/, out)
  end

  def test_an_unknown_command_is_a_usage_error
    status, _out, err = run_cli('frobnicate')
    assert_equal 1, status
    assert_match(/unknown command/, err)
  end

  def test_a_bad_duration_is_a_usage_error_rather_than_a_crash
    status, _out, err = run_cli('report', '--since', 'soonish')
    assert_equal 1, status
    assert_match(/duration/, err)
  end

  def test_help_is_available_per_command_and_exits_cleanly
    %w[record status report backfill].each do |command|
      status, out, = run_cli(command, '--help')
      assert_equal 0, status, "#{command} --help should succeed"
      assert_match(/Usage: tinaja-power #{command}/, out)
    end
  end

  def test_record_is_quiet_when_nothing_changed
    # It runs every thirty seconds forever. Logging every no-op would bury everything else.
    assert_equal 0, run_cli('record').first
    status, out, = run_cli('record')
    assert_equal 0, status
    assert_empty out
  end

  def test_record_verbose_always_speaks
    run_cli('record')  # first one changes the state
    _status, out, = run_cli('record', '--verbose')
    assert_match(/no change/, out)
  end

  def test_record_says_when_the_state_changed
    _status, out, = run_cli('record')
    assert_match(/state changed/, out)
  end

  def test_status_reads_this_machine
    _status, out, = run_cli('status')
    assert_match(/AC|battery|unknown/, out)
  end

  def test_status_json_parses_and_carries_the_tri_state
    _status, out, = run_cli('status', '--json')
    parsed = JSON.parse(out)
    assert_includes [true, false, nil], parsed['ac_online']
    assert_includes [true, false], parsed['has_route']
  end

  def test_report_on_an_empty_database_says_so_rather_than_claiming_uptime
    run_cli('record')
    _status, out, = run_cli('report')
    assert_match(/Never on battery/, out)
    assert_match(/Observed/, out)
  end

  def test_report_lists_an_outage_with_its_length
    seed([[T0, T0 + 3 * 3600, 0]])

    _status, out, = run_cli('report')
    assert_match(/1 outage, 3h 0m on battery/, out)
    assert_match(/longest 3h 0m/, out)
  end

  def test_report_always_shows_coverage
    # The line that stops the numbers above it from reading as a claim about the whole
    # period. It is not optional.
    seed([[T0, T0 + 3600, 0], [T0 + 3600, T0 + 40 * 3600, nil]])
    _status, out, = run_cli('report')
    assert_match(/Observed 1h 0m of/, out)
    assert_match(/unknown/, out)
  end

  def test_report_json_is_machine_readable
    seed([[T0, T0 + 3600, 0]])
    _status, out, = run_cli('report', '--json')
    parsed = JSON.parse(out)
    assert_equal 1, parsed['totals']['outage_count']
    assert_equal 3600.0, parsed['totals']['outage_seconds']
    # Seeded history knows nothing about the router, so it says nothing about the router.
    assert_nil parsed['outages'].first['net_blackout_seconds']
  end

  def test_a_limit_lists_the_most_recent_but_still_totals_the_whole_window
    store = TinajaPower::Store.new(@db)
    3.times { |i| store.seed([[T0 + (i * 2 * 3600), T0 + ((i * 2) + 1) * 3600, 0]]) }
    store.close

    _status, out, = run_cli('report', '--limit', '1')
    # One listed, and it says so rather than quietly implying there was only one.
    assert_match(/3 outages,/, out)
    assert_match(/showing 1 of 3/, out)
  end

  def test_the_default_database_lives_outside_any_checkout
    # The history must survive an upgrade, a reinstall, or a deleted clone.
    default = TinajaPower::CLI::DEFAULT_DB
    refute_match(/Developer/, default)
    assert_match(%r{\A~/\.local/share/}, default)
  end
end

# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require_relative 'fake_machine'
require_relative '../lib/tinaja_power/sysfs'

class SysfsTest < Minitest::Test
  include TinajaPower::FakeMachine

  def setup
    @root = TinajaPower::FakeMachine.fresh_root
  end

  def teardown
    TinajaPower::FakeMachine.discard(@root)
  end

  def test_on_ac
    assert_equal true, fake_machine.ac_online
  end

  def test_unplugged
    assert_equal false, fake_machine(ac_online: '0').ac_online
  end

  def test_no_mains_supply_is_unknown_not_battery
    # There is no way to tell "no adapter" from "adapter we cannot read", and guessing
    # either way would invent outages that did not happen.
    assert_nil machine_without_ac.ac_online
  end

  def test_an_unreadable_adapter_is_unknown
    machine = fake_machine
    File.unlink(@root + 'sys/class/power_supply/ADP1/online')
    assert_nil machine.ac_online
  end

  def test_a_mains_supply_without_an_online_file_is_unknown
    machine = fake_machine(ac_online: nil)
    write_supply(@root + 'sys/class/power_supply/ADP2', 'Mains')
    assert_nil machine.ac_online
  end

  def test_a_missing_power_supply_tree_is_unknown
    machine = fake_machine
    FileUtils.remove_entry(@root + 'sys/class/power_supply')
    assert_nil machine.ac_online
    assert_nil machine.battery_pct
  end

  def test_one_of_two_mains_online_counts_as_on_ac
    machine = fake_machine
    write_supply(@root + 'sys/class/power_supply/ADP2', 'Mains', online: '0')
    assert_equal true, machine.ac_online
  end

  def test_battery_percentage
    assert_equal 88, fake_machine.battery_pct
  end

  def test_charge_in_watt_hours
    # The kernel reports micro-watt-hours; 2_516_000 is a 2.516 Wh pack.
    assert_in_delta 2.516, fake_machine.charge_wh, 0.0001
  end

  def test_a_cell_that_is_not_present_is_ignored
    # A slot that reports present = 0 is a placeholder, not a battery at 0%.
    assert_nil fake_machine(battery_present: '0').battery_pct
  end

  def test_a_supply_that_is_not_a_battery_is_not_treated_as_one
    machine = fake_machine
    (@root + 'sys/class/power_supply/BAT0/type').write("Unknown\n")
    assert_nil machine.battery_pct
  end

  def test_a_battery_without_a_capacity_file
    machine = fake_machine
    File.unlink(@root + 'sys/class/power_supply/BAT0/capacity')
    assert_nil machine.battery_pct
  end

  def test_has_route
    assert_equal true, fake_machine.has_route
  end

  def test_no_default_route
    machine = fake_machine(route: false)
    assert_nil machine.iface
    assert_equal false, machine.has_route
  end

  def test_unreadable_procfs_is_no_route
    machine = fake_machine
    File.unlink(@root + 'proc/net/route')
    assert_nil machine.iface
  end

  def test_reading_takes_one_consistent_pass
    reading = fake_machine(ac_online: '0', battery_capacity: '61').reading
    assert_equal false, reading.ac_online
    assert_equal 61, reading.battery_pct
    assert_equal true, reading.has_route
    assert_equal 'wlp3s0', reading.iface
  end

  def test_reading_of_a_machine_with_no_battery_at_all
    machine = fake_machine
    FileUtils.remove_entry(@root + 'sys/class/power_supply/BAT0')
    reading = machine.reading
    assert_nil reading.battery_pct
    assert_nil reading.charge_wh
    assert_equal true, reading.ac_online
  end
end

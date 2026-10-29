# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loto_power/sysfs'

# The same battery, network and adapter, read from this machine rather than a fixture.
# A parser that only ever sees files it was written against is not a parser yet.
class SysfsAgainstTheRealMachineTest < Minitest::Test
  def setup
    @machine = LotoPower::Sysfs.new
  end

  def test_it_reads_something_coherent
    reading = @machine.reading
    refute_nil reading.ac_online, 'no mains supply was readable'
    refute_nil reading.battery_pct, 'no battery capacity was readable'
    assert_includes [true, false], reading.has_route
  end

  def test_charge_is_a_plausible_watt_hour_value
    charge = @machine.charge_wh
    refute_nil charge
    assert_operator charge, :>, 0, 'a laptop with a fitted battery reports zero charge'
    assert_operator charge, :<, 200, 'a battery reporting this much is not a battery'
  end
end

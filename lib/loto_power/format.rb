# frozen_string_literal: true

require 'time'

module LotoPower
  # Rendering. Kept out of Report so that the numbers are testable without asserting on
  # strings, and so that --json and the terminal text cannot drift apart.
  module Format
    module_function

    # 5h 48m. Seconds only when there really are seconds, because "0s" for an outage that
    # lasted under a minute is noise, and "47s" is genuinely worth knowing.
    #
    # Two units at most, dropping a zero remainder but never silently swallowing one. A
    # week-scale figure that reads "1w 0d" when the truth is "1w 3h" is the kind of small
    # dishonesty that makes a report untrustworthy.
    def duration(seconds)
      total = seconds.round
      return "#{total}s" if total < 60

      minutes = total / 60
      return "#{minutes}m" if minutes < 60

      hours = minutes / 60
      return "#{hours}h #{minutes % 60}m" if hours < 24

      days = hours / 24
      return "#{days}d #{hours % 24}h" if days < 7

      parts = ["#{days / 7}w"]
      parts << "#{days % 7}d" if (days % 7).positive?
      parts << "#{hours % 24}h" if (hours % 24).positive?
      parts.join(' ')
    end

    def percent(ratio)
      return 'n/a' if ratio.nil?

      format('%.1f%%', ratio * 100)
    end

    def clock(epoch)
      Time.at(epoch).strftime('%a %d %b %H:%M')
    end

    # The live reading, in the order a person wants it: is there power, how much is left,
    # and is anything on the other end.
    def status(reading)
      parts = [case reading.ac_online
               when true then 'On AC'
               when false then 'On battery'
               else 'AC unknown — no mains supply could be read'
               end]
      parts << "#{reading.battery_pct}%" if reading.battery_pct
      parts << "#{reading.charge_wh} Wh" if reading.charge_wh
      parts << (reading.has_route ? "route via #{reading.iface}" : 'no default route')
      parts.join(' — ')
    end
  end
end

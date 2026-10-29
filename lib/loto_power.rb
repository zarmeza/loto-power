# frozen_string_literal: true

require_relative 'loto_power/version'
require_relative 'loto_power/format'
require_relative 'loto_power/journal'
require_relative 'loto_power/report'
require_relative 'loto_power/store'
require_relative 'loto_power/sysfs'

# Records when the office loses power.
#
# The laptop's mains adapter is the reference signal: on AC means the office has power,
# on battery means it does not. Everything else in this gem exists to make that one
# reading into a history that can be believed — to record what happened, to mark the
# stretches when the laptop was off and therefore saw nothing, and to never let those
# stretches be quietly counted as uptime.
module LotoPower
end

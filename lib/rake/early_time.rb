module Rake
  # EarlyTime is a fake timestamp that occurs _before_ any other time value.
  class EarlyTime
    include Comparable
    include Singleton

    def <=>(other)
      -1
    end

    def to_s
      "<EARLY TIME>"
    end
  end # class Rake::EarlyTime

  EARLY = EarlyTime.instance
end # module Rake

# ###########################################################################
# Extensions to time to allow comparisons with an early time class.
#
class Time
  alias rake_original_time_compare :<=>
  def <=>(other)
    if Rake::EarlyTime === other
      - other.<=>(self)
    else
      rake_original_time_compare(other)
    end
  end
end # class Time


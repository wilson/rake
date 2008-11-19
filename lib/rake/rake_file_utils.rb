# ###########################################################################
# This a FileUtils extension that defines several additional commands to be
# added to the FileUtils utility functions.
#
module FileUtils
  RUBY = File.join(Config::CONFIG['bindir'], Config::CONFIG['ruby_install_name']).
    sub(/.*\s.*/m, '"\&"')

  OPT_TABLE['sh']  = %w(noop verbose)
  OPT_TABLE['ruby'] = %w(noop verbose)

  # Run the system command +cmd+. If multiple arguments are given the command
  # is not run with the shell (same semantics as Kernel::exec and
  # Kernel::system).
  #
  # Example:
  #   sh %{ls -ltr}
  #
  #   sh 'ls', 'file with spaces'
  #
  #   # check exit status after command runs
  #   sh %{grep pattern file} do |ok, res|
  #     if ! ok
  #       puts "pattern not found (status = #{res.exitstatus})"
  #     end
  #   end
  #
  def sh(*cmd, &block)
    options = (Hash === cmd.last) ? cmd.pop : {}
    unless block_given?
      show_command = cmd.join(" ")
      show_command = show_command[0,42] + "..." unless $trace
      block = lambda { |ok, status|
        ok or fail "Command failed with status (#{status.exitstatus}): [#{show_command}]"
      }
    end
    if RakeFileUtils.verbose_flag == :default
      options[:verbose] = false
    else
      options[:verbose] ||= RakeFileUtils.verbose_flag
    end
    options[:noop]    ||= RakeFileUtils.nowrite_flag
    rake_check_options options, :noop, :verbose
    rake_output_message cmd.join(" ") if options[:verbose]
    unless options[:noop]
      res = rake_system(*cmd)
      block.call(res, $?)
    end
  end

  def rake_system(*cmd)
    if Rake::Win32.windows?
      Rake::Win32.rake_system(*cmd)
    else
      system(*cmd)
    end
  end
  private :rake_system

  # Run a Ruby interpreter with the given arguments.
  #
  # Example:
  #   ruby %{-pe '$_.upcase!' <README}
  #
  def ruby(*args,&block)
    options = (Hash === args.last) ? args.pop : {}
    if args.length > 1 then
      sh(*([RUBY] + args + [options]), &block)
    else
      sh("#{RUBY} #{args.first}", options, &block)
    end
  end

  LN_SUPPORTED = [true]

  #  Attempt to do a normal file link, but fall back to a copy if the link
  #  fails.
  def safe_ln(*args)
    unless LN_SUPPORTED[0]
      cp(*args)
    else
      begin
        ln(*args)
      rescue StandardError, NotImplementedError => ex
        LN_SUPPORTED[0] = false
        cp(*args)
      end
    end
  end

  # Split a file path into individual directory names.
  #
  # Example:
  #   split_all("a/b/c") =>  ['a', 'b', 'c']
  #
  def split_all(path)
    head, tail = File.split(path)
    return [tail] if head == '.' || tail == '/'
    return [head, tail] if head == '/'
    return split_all(head) + [tail]
  end
end

# ###########################################################################
# RakeFileUtils provides a custom version of the FileUtils methods that
# respond to the <tt>verbose</tt> and <tt>nowrite</tt> commands.
#
module RakeFileUtils
  include FileUtils

  class << self
    attr_accessor :verbose_flag, :nowrite_flag
  end
  RakeFileUtils.verbose_flag = :default
  RakeFileUtils.nowrite_flag = false

  $fileutils_verbose = true
  $fileutils_nowrite = false

  FileUtils::OPT_TABLE.each do |name, opts|
    default_options = []
    if opts.include?(:verbose) || opts.include?("verbose")
      default_options << ':verbose => RakeFileUtils.verbose_flag'
    end
    if opts.include?(:noop) || opts.include?("noop")
      default_options << ':noop => RakeFileUtils.nowrite_flag'
    end

    next if default_options.empty?
    module_eval(<<-EOS, __FILE__, __LINE__ + 1)
    def #{name}( *args, &block )
      super(
        *rake_merge_option(args,
          #{default_options.join(', ')}
          ), &block)
    end
    EOS
  end

  # Get/set the verbose flag controlling output from the FileUtils utilities.
  # If verbose is true, then the utility method is echoed to standard output.
  #
  # Examples:
  #    verbose              # return the current value of the verbose flag
  #    verbose(v)           # set the verbose flag to _v_.
  #    verbose(v) { code }  # Execute code with the verbose flag set temporarily to _v_.
  #                         # Return to the original value when code is done.
  def verbose(value=nil)
    oldvalue = RakeFileUtils.verbose_flag
    RakeFileUtils.verbose_flag = value unless value.nil?
    if block_given?
      begin
        yield
      ensure
        RakeFileUtils.verbose_flag = oldvalue
      end
    end
    RakeFileUtils.verbose_flag
  end

  # Get/set the nowrite flag controlling output from the FileUtils utilities.
  # If verbose is true, then the utility method is echoed to standard output.
  #
  # Examples:
  #    nowrite              # return the current value of the nowrite flag
  #    nowrite(v)           # set the nowrite flag to _v_.
  #    nowrite(v) { code }  # Execute code with the nowrite flag set temporarily to _v_.
  #                         # Return to the original value when code is done.
  def nowrite(value=nil)
    oldvalue = RakeFileUtils.nowrite_flag
    RakeFileUtils.nowrite_flag = value unless value.nil?
    if block_given?
      begin
        yield
      ensure
        RakeFileUtils.nowrite_flag = oldvalue
      end
    end
    oldvalue
  end

  # Use this function to prevent protentially destructive ruby code from
  # running when the :nowrite flag is set.
  #
  # Example:
  #
  #   when_writing("Building Project") do
  #     project.build
  #   end
  #
  # The following code will build the project under normal conditions. If the
  # nowrite(true) flag is set, then the example will print:
  #      DRYRUN: Building Project
  # instead of actually building the project.
  #
  def when_writing(msg=nil)
    if RakeFileUtils.nowrite_flag
      puts "DRYRUN: #{msg}" if msg
    else
      yield
    end
  end

  # Merge the given options with the default values.
  def rake_merge_option(args, defaults)
    if Hash === args.last
      defaults.update(args.last)
      args.pop
    end
    args.push defaults
    args
  end
  private :rake_merge_option

  # Send the message to the default rake output (which is $stderr).
  def rake_output_message(message)
    $stderr.puts(message)
  end
  private :rake_output_message

  # Check that the options do not contain options not listed in +optdecl+.  An
  # ArgumentError exception is thrown if non-declared options are found.
  def rake_check_options(options, *optdecl)
    h = options.dup
    optdecl.each do |name|
      h.delete name
    end
    raise ArgumentError, "no such option: #{h.keys.join(' ')}" unless h.empty?
  end
  private :rake_check_options

  extend self
end

# ###########################################################################
# Include the FileUtils file manipulation functions in the top level module,
# but mark them private so that they don't unintentionally define methods on
# other objects.

include RakeFileUtils
private(*FileUtils.instance_methods(false))
private(*RakeFileUtils.instance_methods(false))


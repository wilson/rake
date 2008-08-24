module Rake

  # Default Rakefile loader used by +import+.
  class DefaultLoader
    def load(fn)
      Kernel.load(File.expand_path(fn))
    end
  end

  ######################################################################
  # Rake main application object.  When invoking +rake+ from the
  # command line, a Rake::Application object is created and run.
  #
  class Application
    include TaskManager

    # The name of the application (typically 'rake')
    attr_reader :name

    # The original directory where rake was invoked.
    attr_reader :original_dir

    # Name of the actual rakefile used.
    attr_reader :rakefile

    # List of the top level task names (task names from the command line).
    attr_reader :top_level_tasks

    DEFAULT_RAKEFILES = ['rakefile', 'Rakefile', 'rakefile.rb', 'Rakefile.rb'].freeze

    # Initialize a Rake::Application object.
    def initialize
      super
      @name = 'rake'
      @rakefiles = DEFAULT_RAKEFILES.dup
      @rakefile = nil
      @pending_imports = []
      @imported = []
      @loaders = {}
      @default_loader = Rake::DefaultLoader.new
      @original_dir = Dir.pwd
      @top_level_tasks = []
      add_loader('rf', DefaultLoader.new)
      add_loader('rake', DefaultLoader.new)
      @tty_output = STDOUT.tty?
    end

    # Run the Rake application.  The run method performs the following three steps:
    #
    # * Initialize the command line options (+init+).
    # * Define the tasks (+load_rakefile+).
    # * Run the top level tasks (+run_tasks+).
    #
    # If you wish to build a custom rake command, you should call +init+ on your
    # application.  The define any tasks.  Finally, call +top_level+ to run your top
    # level tasks.
    def run
      standard_exception_handling do
        init
        load_rakefile
        top_level
      end
    end

    # Initialize the command line parameters and app name.
    def init(app_name='rake')
      standard_exception_handling do
        @name = app_name
        collect_tasks handle_options
      end
    end

    # Find the rakefile and then load it and any pending imports.
    def load_rakefile
      standard_exception_handling do
        raw_load_rakefile
      end
    end

    # Run the top level tasks of a Rake application.
    def top_level
      standard_exception_handling do
        if options.show_tasks
          display_tasks_and_comments
        elsif options.show_prereqs
          display_prerequisites
        else
          top_level_tasks.each { |task_name| invoke_task(task_name) }
        end
      end
    end

    # Add a loader to handle imported files ending in the extension
    # +ext+.
    def add_loader(ext, loader)
      ext = ".#{ext}" unless ext =~ /^\./
      @loaders[ext] = loader
    end

    # Application options from the command line
    def options
      @options ||= OpenStruct.new
    end

    # private ----------------------------------------------------------------

    def invoke_task(task_string)
      name, args = parse_task_string(task_string)
      t = self[name]
      t.invoke(*args)
    end

    def parse_task_string(string)
      if string =~ /^([^\[]+)(\[(.*)\])$/
        name = $1
        args = $3.split(/\s*,\s*/)
      else
        name = string
        args = []
      end
      [name, args]
    end

    # Provide standard execption handling for the given block.
    def standard_exception_handling
      begin
        yield
      rescue SystemExit => ex
        # Exit silently with current status
        exit(ex.status)
      rescue SystemExit, OptionParser::InvalidOption => ex
        # Exit silently
        exit(1)
      rescue Exception => ex
        # Exit with error message
        $stderr.puts "rake aborted!"
        $stderr.puts ex.message
        if options.trace
          $stderr.puts ex.backtrace.join("\n")
        else
          $stderr.puts ex.backtrace.find {|str| str =~ /#{@rakefile}/ } || ""
          $stderr.puts "(See full trace by running task with --trace)"
        end
        exit(1)
      end
    end

    # True if one of the files in RAKEFILES is in the current directory.
    # If a match is found, it is copied into @rakefile.
    def have_rakefile
      @rakefiles.each do |fn|
        if File.exist?(fn) || fn == ''
          @rakefile = fn
          return true
        end
      end
      return false
    end

    # True if we are outputting to TTY, false otherwise
    def tty_output?
      @tty_output
    end

    # Override the detected TTY output state (mostly for testing)
    def tty_output=( tty_output_state )
      @tty_output = tty_output_state
    end

    # We will truncate output if we are outputting to a TTY or if we've been
    # given an explicit column width to honor
    def truncate_output?
      tty_output? || ENV['RAKE_COLUMNS']
    end

    # Display the tasks and dependencies.
    def display_tasks_and_comments
      displayable_tasks = tasks.select { |t|
        t.comment && t.name =~ options.show_task_pattern
      }
      if options.full_description
        displayable_tasks.each do |t|
          puts "rake #{t.name_with_args}"
          t.full_comment.split("\n").each do |line|
            puts "    #{line}"
          end
          puts
        end
      else
        width = displayable_tasks.collect { |t| t.name_with_args.length }.max || 10
        max_column = truncate_output? ? terminal_width - name.size - width - 7 : nil
        displayable_tasks.each do |t|
          printf "#{name} %-#{width}s  # %s\n",
            t.name_with_args, max_column ? truncate(t.comment, max_column) : t.comment
        end
      end
    end

    def terminal_width
      if ENV['RAKE_COLUMNS']
        result = ENV['RAKE_COLUMNS'].to_i
      else
        result = unix? ? dynamic_width : 80
      end
      (result < 10) ? 80 : result
    rescue
      80
    end

    # Calculate the dynamic width of the 
    def dynamic_width
      @dynamic_width ||= (dynamic_width_stty.nonzero? || dynamic_width_tput)
    end

    def dynamic_width_stty
      %x{stty size 2>/dev/null}.split[1].to_i
    end

    def dynamic_width_tput
      %x{tput cols 2>/dev/null}.to_i
    end

    def unix?
      RUBY_PLATFORM =~ /(aix|darwin|linux|(net|free|open)bsd|cygwin|solaris|irix|hpux|)/i
    end
    
    def truncate(string, width)
      if string.length <= width
        string
      else
        ( string[0, width-3] || "" ) + "..."
      end
    end

    # Display the tasks and prerequisites
    def display_prerequisites
      tasks.each do |t|
        puts "rake #{t.name}"
        t.prerequisites.each { |pre| puts "    #{pre}" }
      end
    end

    # Return a list of the command line options supported by the
    # program.
    def command_line_options
      OPTIONS.collect { |lst| lst[0..-2] }
    end

    # Read and handle the command line options.
    def handle_options
      # optparse version of OPTIONS
      op_options = [
        ['--classic-namespace', '-C', "Put Task and FileTask in the top level namespace",
          lambda { |value|
            require 'rake/classic_namespace'
            options.classic_namespace = true
          }
        ],
        ['--describe', '-D [PATTERN]', "Describe the tasks (matching optional PATTERN), then exit.",
          lambda { |value|
            options.show_tasks = true
            options.full_description = true
            options.show_task_pattern = Regexp.new(value || '')
          }
        ],
        ['--dry-run', '-n', "Do a dry run without executing actions.",
          lambda { |value|
            verbose(true)
            nowrite(true)
            options.dryrun = true
            options.trace = true
          }
        ],
        ['--execute',  '-e CODE', "Execute some Ruby code and exit.",
          lambda { |value|
            eval(value)
            exit
          }
        ],
        ['--execute-print',  '-p CODE', "Execute some Ruby code, print the result, then exit.",
          lambda { |value|
            puts eval(value)
            exit
          }
        ],
        ['--execute-continue',  '-E',
          "Execute some Ruby code, then continue with normal task processing.",
          lambda { |value| eval(value) }            
        ],
        ['--libdir', '-I LIBDIR', "Include LIBDIR in the search path for required modules.",
          lambda { |value| $:.push(value) }
        ],
        ['--nosearch', '-N', "Do not search parent directories for the Rakefile.",
          lambda { |value| options.nosearch = true }
        ],
        ['--prereqs', '-P', "Display the tasks and dependencies, then exit.",
          lambda { |value| options.show_prereqs = true }
        ],
        ['--quiet', '-q', "Do not log messages to standard output.",
          lambda { |value| verbose(false) }
        ],
        ['--rakefile', '-f [FILE]', "Use FILE as the rakefile.",
          lambda { |value| 
            value ||= ''
            @rakefiles.clear 
            @rakefiles << value
          }
        ],
        ['--rakelibdir', '--rakelib', '-R RAKELIBDIR',
          "Auto-import any .rake files in RAKELIBDIR. (default is 'rakelib')",
          lambda { |value| options.rakelib = value.split(':') }
        ],
        ['--require', '-r MODULE', "Require MODULE before executing rakefile.",
          lambda { |value|
            begin
              require value
            rescue LoadError => ex
              begin
                rake_require value
              rescue LoadError => ex2
                raise ex
              end
            end
          }
        ],
        ['--rules', "Trace the rules resolution.",
          lambda { |value| options.trace_rules = true }
        ],
        ['--silent', '-s', "Like --quiet, but also suppresses the 'in directory' announcement.",
          lambda { |value|
            verbose(false)
            options.silent = true
          }
        ],
        ['--tasks', '-T [PATTERN]', "Display the tasks (matching optional PATTERN) with descriptions, then exit.",
          lambda { |value|
            options.show_tasks = true
            options.show_task_pattern = Regexp.new(value || '')
            options.full_description = false
          }
        ],
        ['--trace', '-t', "Turn on invoke/execute tracing, enable full backtrace.",
          lambda { |value|
            options.trace = true
            verbose(true)
          }
        ],
        ['--verbose', '-v', "Log message to standard output (default).",
          lambda { |value| verbose(true) }
        ],
        ['--version', '-V', "Display the program version.",
          lambda { |value|
            puts "rake, version #{RAKEVERSION}"
            exit
          }
        ],
      ]

      options.rakelib = ['rakelib']

      # opts = GetoptLong.new(*command_line_options)
      # opts.each { |opt, value| do_option(opt, value) }

      parsed_argv = nil
      opts = OptionParser.new do |opts|
        opts.banner = "rake [-f rakefile] {options} targets..."
        opts.separator ""
        opts.separator "Options are ..."

      	opts.on_tail("-h", "--help", "-H", "Display this help message.") do
    	  	puts opts
    		  exit
      	end

        op_options.each { |args| opts.on(*args) }
      	parsed_argv = opts.parse(ARGV)
      end

      # If class namespaces are requested, set the global options
      # according to the values in the options structure.
      if options.classic_namespace
        $show_tasks = options.show_tasks
        $show_prereqs = options.show_prereqs
        $trace = options.trace
        $dryrun = options.dryrun
        $silent = options.silent
      end
      return parsed_argv
    rescue NoMethodError => ex
      raise OptionParser::InvalidOption, "While parsing options, error = #{ex.class}:#{ex.message}"
    end

    # Similar to the regular Ruby +require+ command, but will check
    # for .rake files in addition to .rb files.
    def rake_require(file_name, paths=$LOAD_PATH, loaded=$")
      return false if loaded.include?(file_name)
      paths.each do |path|
        fn = file_name + ".rake"
        full_path = File.join(path, fn)
        if File.exist?(full_path)
          load full_path
          loaded << fn
          return true
        end
      end
      fail LoadError, "Can't find #{file_name}"
    end

    def raw_load_rakefile # :nodoc:
      here = Dir.pwd
      while ! have_rakefile
        Dir.chdir("..")
        if Dir.pwd == here || options.nosearch
          fail "No Rakefile found (looking for: #{@rakefiles.join(', ')})"
        end
        here = Dir.pwd
      end
      puts "(in #{Dir.pwd})" unless options.silent
      $rakefile = @rakefile
      load File.expand_path(@rakefile) if @rakefile != ''
      options.rakelib.each do |rlib|
        Dir["#{rlib}/*.rake"].each do |name| add_import name end
      end
      load_imports
    end

    # Collect the list of tasks on the command line.  If no tasks are
    # given, return a list containing only the default task.
    # Environmental assignments are processed at this time as well.
    def collect_tasks(argv)
      @top_level_tasks = []
      argv.each do |arg|
        if arg =~ /^(\w+)=(.*)$/
          ENV[$1] = $2
        else
          @top_level_tasks << arg unless arg =~ /^-/
        end
      end
      @top_level_tasks.push("default") if @top_level_tasks.size == 0
    end

    # Add a file to the list of files to be imported.
    def add_import(fn)
      @pending_imports << fn
    end

    # Load the pending list of imported files.
    def load_imports
      while fn = @pending_imports.shift
        next if @imported.member?(fn)
        if fn_task = lookup(fn)
          fn_task.invoke
        end
        ext = File.extname(fn)
        loader = @loaders[ext] || @default_loader
        loader.load(fn)
        @imported << fn
      end
    end

    # Warn about deprecated use of top level constant names.
    def const_warning(const_name)
      @const_warning ||= false
      if ! @const_warning
        $stderr.puts %{WARNING: Deprecated reference to top-level constant '#{const_name}' } +
          %{found at: #{rakefile_location}} # '
        $stderr.puts %{    Use --classic-namespace on rake command}
        $stderr.puts %{    or 'require "rake/classic_namespace"' in Rakefile}
      end
      @const_warning = true
    end

    def rakefile_location
      begin
        fail
      rescue RuntimeError => ex
        ex.backtrace.find {|str| str =~ /#{@rakefile}/ } || ""
      end
    end
  end # class Rake::Application
end # module Rake

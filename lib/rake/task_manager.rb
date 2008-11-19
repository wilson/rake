module Rake
  # Raised when a declared rule is 16 or more dependencies deep
  class RuleRecursionOverflowError < StandardError
    def initialize(*args)
      super
      @targets = []
    end

    def add_target(target)
      @targets << target
    end

    def message
      super + ": [" + @targets.reverse.join(' => ') + "]"
    end
  end

  ####################################################################
  # The TaskManager module is a mixin for managing tasks.
  module TaskManager
    # Track the last comment made in the Rakefile.
    attr_accessor :last_description
    alias :last_comment :last_description    # Backwards compatibility

    def initialize
      super
      @tasks = Hash.new
      @rules = Array.new
      @scope = Array.new
      @last_description = nil
    end

    def create_rule(*args, &block)
      pattern, arg_names, deps = resolve_args(args)
      pattern = Regexp.new(Regexp.quote(pattern) + '$') if String === pattern
      @rules << [pattern, deps, block]
    end

    def define_task(task_class, *args, &block)
      task_name, arg_names, deps = resolve_args(args)
      task_name = task_class.scope_name(@scope, task_name)
      deps = [deps] unless deps.respond_to?(:to_ary)
      deps = deps.collect {|d| d.to_s }
      task = intern(task_class, task_name)
      task.set_arg_names(arg_names) unless arg_names.empty?
      task.add_description(@last_description)
      @last_description = nil
      task.enhance(deps, &block)
      task
    end

    # Lookup a task.  Return an existing task if found, otherwise
    # create a task of the current type.
    def intern(task_class, task_name)
      @tasks[task_name.to_s] ||= task_class.new(task_name, self)
    end

    # Find a matching task for +task_name+.
    def [](task_name, scopes=nil)
      task_name = task_name.to_s
      self.lookup(task_name, scopes) or
        enhance_with_matching_rule(task_name) or
        synthesize_file_task(task_name) or
        fail "Don't know how to build task '#{task_name}'"
    end

    def synthesize_file_task(task_name)
      return nil unless File.exist?(task_name)
      define_task(Rake::FileTask, task_name)
    end

    # Resolve the arguments for a task/rule.  Returns a triplet of
    # [task_name, arg_name_list, prerequisites].
    def resolve_args(args)
      if args.last.is_a?(Hash)
        deps = args.pop
        resolve_args_with_dependencies(args, deps)
      else
        resolve_args_without_dependencies(args)
      end
    end

    # Resolve task arguments for a task or rule when there are no
    # dependencies declared.
    #
    # The patterns recognized by this argument resolving function are:
    #
    #   task :t
    #   task :t, [:a]
    #   task :t, :a                 (deprecated)
    #
    def resolve_args_without_dependencies(args)
      task_name = args.shift
      if args.size == 1 && args.first.respond_to?(:to_ary)
        arg_names = args.first.to_ary
      else
        arg_names = args
      end
      [task_name, arg_names, []]
    end
    private :resolve_args_without_dependencies

    # Resolve task arguments for a task or rule when there are
    # dependencies declared.
    #
    # The patterns recognized by this argument resolving function are:
    #
    #   task :t => [:d]
    #   task :t, [a] => [:d]
    #   task :t, :needs => [:d]                 (deprecated)
    #   task :t, :a, :needs => [:d]             (deprecated)
    #
    def resolve_args_with_dependencies(args, hash) # :nodoc:
      fail "Task Argument Error" if hash.size != 1
      key, value = hash.map { |k, v| [k,v] }.first
      if args.empty?
        task_name = key
        arg_names = []
        deps = value
      elsif key == :needs
        task_name = args.shift
        arg_names = args
        deps = value
      else
        task_name = args.shift
        arg_names = key
        deps = value
      end
      deps = [deps] unless deps.respond_to?(:to_ary)
      [task_name, arg_names, deps]
    end
    private :resolve_args_with_dependencies

    # If a rule can be found that matches the task name, enhance the
    # task with the prerequisites and actions from the rule.  Set the
    # source attribute of the task appropriately for the rule.  Return
    # the enhanced task or nil of no rule was found.
    def enhance_with_matching_rule(task_name, level=0)
      fail Rake::RuleRecursionOverflowError,
        "Rule Recursion Too Deep" if level >= 16
      @rules.each do |pattern, extensions, block|
        if md = pattern.match(task_name)
          task = attempt_rule(task_name, extensions, block, level)
          return task if task
        end
      end
      nil
    rescue Rake::RuleRecursionOverflowError => ex
      ex.add_target(task_name)
      fail ex
    end

    # List of all defined tasks in this application.
    def tasks
      @tasks.values.sort_by { |t| t.name }
    end

    # List of all the tasks defined in the given scope (and its
    # sub-scopes).
    def tasks_in_scope(scope)
      prefix = scope.join(":")
      tasks.select { |t|
        /^#{prefix}:/ =~ t.name
      }
    end

    # Clear all tasks in this application.
    def clear
      @tasks.clear
      @rules.clear
    end

    # Lookup a task, using scope and the scope hints in the task name.
    # This method performs straight lookups without trying to
    # synthesize file tasks or rules.  Special scope names (e.g. '^')
    # are recognized.  If no scope argument is supplied, use the
    # current scope.  Return nil if the task cannot be found.
    def lookup(task_name, initial_scope=nil)
      initial_scope ||= @scope
      task_name = task_name.to_s
      if task_name =~ /^rake:/
        scopes = []
        task_name = task_name.sub(/^rake:/, '')
      elsif task_name =~ /^(\^+)/
        scopes = initial_scope[0, initial_scope.size - $1.size]
        task_name = task_name.sub(/^(\^+)/, '')
      else
        scopes = initial_scope
      end
      lookup_in_scope(task_name, scopes)
    end

    # Lookup the task name
    def lookup_in_scope(name, scope)
      n = scope.size
      while n >= 0
        tn = (scope[0,n] + [name]).join(':')
        task = @tasks[tn]
        return task if task
        n -= 1
      end
      nil
    end
    private :lookup_in_scope

    # Return the list of scope names currently active in the task
    # manager.
    def current_scope
      @scope.dup
    end

    # Evaluate the block in a nested namespace named +name+.  Create
    # an anonymous namespace if +name+ is nil.
    def in_namespace(name)
      name ||= generate_name
      @scope.push(name)
      ns = NameSpace.new(self, @scope)
      yield(ns)
      ns
    ensure
      @scope.pop
    end

    # Completely removes a single task (and its enhancements) by
    # name when passed a +String+ or +Symbol.
    # When passed a +Regexp+, removes all tasks with matching names
    # Use this if you want to completely replace a task instead
    # of extending it.
    def remove_task(name)
      case name
      when Regexp then
        @tasks.delete_if { |k,_| k =~ name }
      else
        @tasks.delete(name.to_s)
      end
    end

    # Returns a +Hash+ with the names of the defined tasks as keys
    # The values are arrays of +Rake::Task+ objects.
    # Modifications to the returned Hash will change the task list
    def task_map
      @tasks
    end

    # Generate an anonymous namespace name.
    def generate_name
      @seed ||= 0
      @seed += 1
      "_anon_#{@seed}"
    end
    private :generate_name

    def trace_rule(level, message)
      puts "#{"    "*level}#{message}" if Rake.application.options.trace_rules
    end
    private :trace_rule

    # Attempt to create a rule given the list of prerequisites.
    def attempt_rule(task_name, extensions, block, level)
      sources = make_sources(task_name, extensions)
      prereqs = sources.collect { |source|
        trace_rule level, "Attempting Rule #{task_name} => #{source}"
        if File.exist?(source) || Rake::Task.task_defined?(source)
          trace_rule level, "(#{task_name} => #{source} ... EXIST)"
          source
        elsif parent = enhance_with_matching_rule(source, level+1)
          trace_rule level, "(#{task_name} => #{source} ... ENHANCE)"
          parent.name
        else
          trace_rule level, "(#{task_name} => #{source} ... FAIL)"
          return nil
        end
      }
      task = FileTask.define_task({task_name => prereqs}, &block)
      task.sources = prereqs
      task
    end
    private :attempt_rule

    # Make a list of sources from the list of file name extensions /
    # translation procs.
    def make_sources(task_name, extensions)
      extensions.collect { |ext|
        case ext
        when /%/
          task_name.pathmap(ext)
        when %r{/}
          ext
        when /^\./
          task_name.ext(ext)
        when String
          ext
        when Proc
          if ext.arity == 1
            ext.call(task_name)
          else
            ext.call
          end
        else
          fail "Don't know how to handle rule dependent: #{ext.inspect}"
        end
      }.flatten
    end
    private :make_sources
  end # module TaskManager
end # module Rake


require 'rake/task'
module Rake

  # #########################################################################
  # A FileTask is a task that includes time based dependencies.  If any of a
  # FileTask's prerequisites have a timestamp that is later than the file
  # represented by this task, then the file must be rebuilt (using the
  # supplied actions).
  #
  class FileTask < Task

    # Is this file task needed?  Yes if it doesn't exist, or if its time stamp
    # is out of date.
    def needed?
      return true unless File.exist?(name)
      return true if out_of_date?(timestamp)
      false
    end

    # Time stamp for file task.
    def timestamp
      if File.exist?(name)
        File.mtime(name.to_s)
      else
        Rake::EARLY
      end
    end

    private

    # Are there any prerequisites with a later time than the given time stamp?
    def out_of_date?(stamp)
      @prerequisites.any? { |n| application[n].timestamp > stamp}
    end

    # ----------------------------------------------------------------
    # Task class methods.
    #
    class << self
      # Apply the scope to the task name according to the rules for this kind
      # of task.  File based tasks ignore the scope when creating the name.
      def scope_name(scope, task_name)
        task_name
      end
    end
  end # class Rake::FileTask

  # #########################################################################
  # A FileCreationTask is a file task that when used as a dependency will be
  # needed if and only if the file has not been created.  Once created, it is
  # not re-triggered if any of its dependencies are newer, nor does trigger
  # any rebuilds of tasks that depend on it whenever it is updated.
  #
  class FileCreationTask < FileTask
    # Is this file task needed?  Yes if it doesn't exist.
    def needed?
      !File.exist?(name)
    end

    # Time stamp for file creation task.  This time stamp is earlier
    # than any other time stamp.
    def timestamp
      Rake::EARLY
    end
  end # class Rake::FileCreationTask
end # module Rake

# Declare a file task.
#
# Example:
#   file "config.cfg" => ["config.template"] do
#     open("config.cfg", "w") do |outfile|
#       open("config.template") do |infile|
#         while line = infile.gets
#           outfile.puts line
#         end
#       end
#     end
#  end
#
def file(*args, &block)
  Rake::FileTask.define_task(*args, &block)
end

# Declare a file creation task.
# (Mainly used for the directory command).
def file_create(args, &block)
  Rake::FileCreationTask.define_task(args, &block)
end

# Declare a set of files tasks to create the given directories on demand.
#
# Example:
#   directory "testdata/doc"
#
def directory(dir)
  Rake.each_dir_parent(dir) do |d|
    file_create d do |t|
      mkdir_p t.name if ! File.exist?(t.name)
    end
  end
end


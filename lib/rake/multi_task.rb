require 'rake/task'

module Rake
  # #########################################################################
  # Same as a regular task, but the immediate prerequisites are done in
  # parallel using Ruby threads.
  #
  class MultiTask < Task
    def invoke_prerequisites(args, invocation_chain)
      threads = @prerequisites.collect { |p|
        Thread.new(p) { |r| application[r].invoke_with_call_chain(args, invocation_chain) }
      }
      threads.each { |t| t.join }
    end
  end
end # module Rake

# Declare a task that performs its prerequisites in parallel. Multitasks does
# *not* guarantee that its prerequisites will execute in any given order
# (which is obvious when you think about it)
#
# Example:
#   multitask :deploy => [:deploy_gem, :deploy_rdoc]
#
def multitask(args, &block)
  Rake::MultiTask.define_task(args, &block)
end


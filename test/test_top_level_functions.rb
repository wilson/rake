#!/usr/bin/env ruby

begin
  require 'rubygems'
rescue LoadError
  # got no gems
end

require 'test/unit'
require 'flexmock/test_unit'
require 'test/capture_stdout'
require 'test/rake_test_setup'
require 'rake'

class TestTopLevelFunctions < Test::Unit::TestCase
  include CaptureStdout
  include TestMethods

  def setup
    super
    @app = Rake.application
    Rake.application = flexmock("app")
  end

  def teardown
    Rake.application = @app
    super
  end

  def test_namespace
    Rake.application.should_receive(:in_namespace).with("xyz", any).once
    namespace "xyz" do end
  end

  def test_import
    Rake.application.should_receive(:add_import).with("x").once.ordered
    Rake.application.should_receive(:add_import).with("y").once.ordered
    Rake.application.should_receive(:add_import).with("z").once.ordered
    import('x', 'y', 'z')
  end

  def test_when_writing
    out = capture_stdout do
      when_writing("NOTWRITING") do
        puts "WRITING"
      end
    end
    assert_equal "WRITING\n", out
  end

  def test_when_not_writing
    RakeFileUtils.nowrite_flag = true
    out = capture_stdout do
      when_writing("NOTWRITING") do
        puts "WRITING"
      end
    end
    assert_equal "DRYRUN: NOTWRITING\n", out
  ensure
    RakeFileUtils.nowrite_flag = false
  end
end

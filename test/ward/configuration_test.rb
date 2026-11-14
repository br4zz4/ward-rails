require "test_helper"

class ConfigurationTest < Minitest::Test
  def test_explicit_dir_wins_over_ward_dir
    config = Ward::Configuration.new
    config.dir = "/from/config"

    with_env("WARD_DIR" => "/from/env") do
      assert_equal "/from/config", config.resolved_dir
    end
  end

  def test_ward_dir_wins_over_current_directory
    with_env("WARD_DIR" => "/from/env") do
      assert_equal "/from/env", Ward::Configuration.new.resolved_dir
    end
  end

  def test_resolved_dir_falls_back_to_current_directory
    script = 'require "ward"; print Ward::Configuration.new.resolved_dir'

    stdout, stderr, status = WardTest.run_ruby({ "WARD_DIR" => nil }, script)

    assert status.success?, stderr
    assert_equal Dir.pwd, stdout
  end
end

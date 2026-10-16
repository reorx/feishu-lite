# Evaluate the generated third-party cask without installing anything.
require "pathname"
HOMEBREW_PREFIX = Pathname.new("/test/homebrew")

class CaskContract
  def initialize
    @dependencies = []
    @commands = []
  end

  def version(value = nil)
    @version = value if value
    @version
  end

  def sha256(value); end
  def url(value); end
  def name(value); end
  def desc(value); end
  def homepage(value); end
  def app(value); end
  def caveats(value); end
  def depends_on(value); @dependencies << value; end
  def postflight(&block); @install = block; end
  def system_command(command, **options); @commands << [command, options]; end

  def verify
    raise "missing dependencies" unless @dependencies.include?({ formula: "uv" }) && @dependencies.include?({ formula: "git" })
    raise "wrong macOS requirement" unless @dependencies.include?({ macos: :sonoma })
    2.times { instance_eval(&@install) } # install and upgrade both reinstall pinned backend
    raise "missing install" unless @commands.size == 2
    @commands.each do |command, options|
      raise "wrong uv" unless command.to_s == "/test/homebrew/opt/uv/bin/uv"
      raise "must abort on failure" unless options[:must_succeed] == true
      args = options[:args]
      raise "wrong install" unless args[0, 6] == ["tool", "install", "--force", "--python", "3.12", "--"]
      raise "unpinned backend" unless args.last.include?("@#{'a' * 40}#subdirectory=backend")
      raise "Finder cannot find backend" unless options[:env]["UV_TOOL_BIN_DIR"] == File.expand_path("~/.local/bin")
    end
  end
end

def cask(token, &block)
  raise "wrong cask name" unless token == "feishu-lite"
  contract = CaskContract.new
  contract.instance_eval(&block)
  contract.verify
end

load ARGV.fetch(0)

require 'rbconfig'
require 'io/console'

class Netrc
  VERSION = "0.11.0"

  # see http://stackoverflow.com/questions/4871309/what-is-the-correct-way-to-detect-if-ruby-is-running-on-windows
  WINDOWS = RbConfig::CONFIG["host_os"] =~ /mswin|mingw|cygwin/
  CYGWIN  = RbConfig::CONFIG["host_os"] =~ /cygwin/

  def self.default_path
    File.join(ENV['NETRC'] || home_path, netrc_filename)
  end

  def self.home_path
    home = Dir.respond_to?(:home) ? Dir.home : ENV['HOME']

    if WINDOWS && !CYGWIN
      home ||= File.join(ENV['HOMEDRIVE'], ENV['HOMEPATH']) if ENV['HOMEDRIVE'] && ENV['HOMEPATH']
      home ||= ENV['USERPROFILE']
      # XXX: old stuff; most likely unnecessary
      home = home.tr("\\", "/") unless home.nil?
    end

    (home && File.readable?(home)) ? home : Dir.pwd
  rescue ArgumentError

    unless WINDOWS
      # Ruby 2.5.x through 2.7.1 (and probably other versions) raises an
      # ArgumentError when the 'HOME' env var is not set and the process is
      # not a subprocess of a login session. That is, it tries to navigate
      # into the password database using the username obtained from
      # getlogin(), whichs will return NULL in such a circumstance. It would
      # be better if it instead tried to do it via the UID obtained from
      # getuid(), which always succeeds. Nevertheless, we'll work around the
      # problem by doing that ourselves here.
      begin
        require 'etc'
      rescue LoadError
        warn "HOME is not set, and the 'etc' module not available; using pwd as home\n"
        return Dir.pwd
      end

      passwd_record = Etc.getpwuid(Process.uid);
      unless passwd_record
        warn "Record for uid #{Process.uid} not found in the password database; using pwd as home\n"
        return Dir.pwd
      end

      return passwd_record.dir
    end

    return Dir.pwd
  end

  def self.netrc_filename
    WINDOWS && !CYGWIN ? "_netrc" : ".netrc"
  end

  def self.config
    @config ||= {}
  end

  def self.configure
    yield(self.config) if block_given?
    self.config
  end

  def self.check_permissions(path)
    perm = File.stat(path).mode & 0777

    # Regardless of whether or not the caller has requested that permissive
    # perms be allowed on the netrc file, we baulk if the perms are too
    # restrictive; we need to be able to read the file.
    unless File.stat(path).readable?
      raise Error, "File '#{path}' is not readable; perms are "+perm.to_s(8)
    end

    if perm != 0400 && perm != 0600 && !(WINDOWS) && !(Netrc.config[:allow_permissive_netrc_file])
      raise Error, "Permission bits for '#{path}' should be 0600 (or 0400), but are "+perm.to_s(8)
    end
  end

  # Reads path and parses it as a .netrc file. If path doesn't
  # exist, returns an empty object. Decrypt paths ending in .gpg.
  def self.read(path=default_path)
    check_permissions(path)
    data = if path =~ /\.gpg$/
      decrypted = if ENV['GPG_AGENT_INFO']
        `gpg --batch --quiet --decrypt #{path}`
      else
         print "Enter passphrase for #{path}: "
         STDIN.noecho do
           `gpg --batch --passphrase-fd 0 --quiet --decrypt #{path}`
         end
      end
      if $?.success?
        decrypted
      else
        raise Error.new("Decrypting #{path} failed.") unless $?.success?
      end
    else
      File.read(path)
    end
    new(path, parse(lex(data.lines.to_a)))
  rescue Errno::ENOENT
    new(path, parse(lex([])))
  end

  class TokenArray < Array
    def take
      if length < 1
        raise Error, "unexpected EOF"
      end
      shift
    end

    def readto
      l = []
      while length > 0 && ! yield(self[0])
        l << shift
      end
      return l.join
    end
  end

  def self.lex(lines)
    tokens = TokenArray.new
    for line in lines
      content, comment = line.split(/(\s*#.*)/m)
      content.each_char do |char|
        case char
        when /\s/
          if tokens.last && tokens.last[-1..-1] =~ /\s/
            tokens.last << char
          else
            tokens << char
          end
        else
          if tokens.last && tokens.last[-1..-1] =~ /\S/
            tokens.last << char
          else
            tokens << char
          end
        end
      end
      if comment
        tokens << comment
      end
    end
    tokens
  end

  def self.skip?(s)
    s =~ /^\s/
  end



  # Returns two values, a header and a list of items.
  # Each item is a tuple, containing some or all of:
  # - machine keyword (including trailing whitespace+comments)
  # - machine name
  # - login keyword (including surrounding whitespace+comments)
  # - login
  # - password keyword (including surrounding whitespace+comments)
  # - password
  # - trailing chars
  # This lets us change individual fields, then write out the file
  # with all its original formatting.
  def self.parse(ts)
    cur, item = [], []

    unless ts.is_a?(TokenArray)
      ts = TokenArray.new(ts)
    end

    pre = ts.readto{|t| t == "machine" || t == "default"}

    while ts.length > 0
      if ts[0] == 'default'
        cur << ts.take.to_sym
        cur << ''
      else
        cur << ts.take + ts.readto{|t| ! skip?(t)}
        cur << ts.take
      end

      login = [nil, nil]
      password = [nil, nil]

      2.times do
        t1 = ts.readto{|t| t == "login" || t == "password" || t == "machine" || t == "default"}

        if ts[0] == "login"
          login = [t1 + ts.take + ts.readto{|t| ! skip?(t)}, ts.take]
        elsif ts[0] == "password"
          password = [t1 + ts.take + ts.readto{|t| ! skip?(t)}, ts.take]
        else
          ts.unshift(t1)
        end
      end

      cur += login
      cur += password
      cur << ts.readto{|t| t == "machine" || t == "default"}

      item << cur
      cur = []
    end

    [pre, item]
  end

  def initialize(path, data)
    @new_item_prefix = ''
    @path = path
    @pre, @data = data

    if @data && @data.last && :default == @data.last[0]
      @default = @data.pop
    else
      @default = nil
    end
  end

  attr_accessor :new_item_prefix

  def [](k)
    if item = @data.detect {|datum| datum[1] == k}
      Entry.new(item[3], item[5])
    elsif @default
      Entry.new(@default[3], @default[5])
    end
  end

  def []=(k, info)
    if item = @data.detect {|datum| datum[1] == k}
      item[3], item[5] = info
    else
      @data << new_item(k, info[0], info[1])
    end
  end

  def length
    @data.length
  end

  def delete(key)
    datum = nil
    for value in @data
      if value[1] == key
        datum = value
        break
      end
    end
    @data.delete(datum)
  end

  def each(&block)
    @data.each(&block)
  end

  def new_item(m, l, p)
    [new_item_prefix+"machine ", m, "\n  login ", l, "\n  password ", p, "\n"]
  end

  def save
    if @path =~ /\.gpg$/
      e = IO.popen("gpg -a --batch --default-recipient-self -e", "r+") do |gpg|
        gpg.puts(unparse)
        gpg.close_write
        gpg.read
      end
      raise Error.new("Encrypting #{@path} failed.") unless $?.success?
      File.open(@path, 'w', 0600) {|file| file.print(e)}
    else
      File.open(@path, 'w', 0600) {|file| file.print(unparse)}
    end
  end

  def unparse
    @pre + @data.map do |datum|
      datum = datum.join
      unless datum[-1..-1] == "\n"
        datum << "\n"
      else
        datum
      end
    end.join
  end

  Entry = Struct.new(:login, :password) do
    alias to_ary to_a
  end

end

class Netrc::Error < ::StandardError
end

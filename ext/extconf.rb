require 'mkmf'
require 'rbconfig'

HERE = File.expand_path(File.dirname(__FILE__))
BUNDLE_PATH = Dir.glob("libmemcached-*").first

SOLARIS_32 = Config::CONFIG['target'] == "i386-pc-solaris2.10"

OPENBSD = Config::CONFIG['host_os'] =~ /^openbsd/
FREEBSD = Config::CONFIG['host_os'] =~ /^freebsd/
BSD = OPENBSD || FREEBSD

$CFLAGS = "#{Config::CONFIG['CFLAGS']} #{$CFLAGS}".gsub("$(cflags)", "").gsub("-fno-common", "").gsub("-Werror=declaration-after-statement", "")
$CFLAGS << " -std=gnu99" if SOLARIS_32
$CFLAGS << " -I/usr/local/include" if BSD
$EXTRA_CONF = " --disable-64bit" if SOLARIS_32
$LDFLAGS = "#{Config::CONFIG['LDFLAGS']} #{$LDFLAGS} -L#{Config::CONFIG['libdir']}".gsub("$(ldflags)", "").gsub("-fno-common", "")
$CXXFLAGS = "#{Config::CONFIG['CXXFLAGS']} -std=gnu++98"
$CC = "CC=#{Config::MAKEFILE_CONFIG["CC"].inspect}"

# JRuby's default configure options can't build libmemcached properly
LIBM_CFLAGS = defined?(JRUBY_VERSION) ? "-fPIC -g -O2" : $CFLAGS
LIBM_LDFLAGS = defined?(JRUBY_VERSION) ? "-fPIC -lsasl2 -lm" : $LDFLAGS

GMAKE_CMD = (BSD || SOLARIS_32) ? "gmake" : "make"
TAR_CMD = (BSD || SOLARIS_32) ? "gtar" : "tar"
PATCH_CMD = SOLARIS_32 ? "gpatch" : "patch"

if ENV['DEBUG']
  puts "Setting debug flags."
  $CFLAGS << " -O0 -ggdb -DHAVE_DEBUG"
  $EXTRA_CONF = ""
end

if OPENBSD
  " --with-libsasl2-prefix=/usr/local".tap do |switch| 
   if $EXTRA_CONF.nil?
      $EXTRA_CONF = switch 
    else
      $EXTRA_CONF << switch
    end
  end
end

def run(cmd, reason)
  puts reason
  puts cmd
  raise "'#{cmd}' failed" unless system(cmd)
end

def check_libmemcached
  return if ENV["EXTERNAL_LIB"]

  $includes = " -I#{HERE}/include"
  $defines = " -DLIBMEMCACHED_WITH_SASL_SUPPORT"
  $libraries = " -L#{HERE}/lib"
  $libraries << " -L/usr/local/lib" if OPENBSD
  $CFLAGS = "#{$includes} #{$libraries} #{$CFLAGS}"
  $LDFLAGS = "-lsasl2 -lm #{$libraries} #{$LDFLAGS}"
  $LIBPATH = ["#{HERE}/lib"]
  $DEFLIBPATH = [] unless SOLARIS_32

  Dir.chdir(HERE) do
    Dir.chdir(BUNDLE_PATH) do
      run("find . | xargs touch", "Touching all files so autoconf doesn't run.")
      run("env CFLAGS='-fPIC #{LIBM_CFLAGS}' LDFLAGS='-fPIC #{LIBM_LDFLAGS}' ./configure --prefix=#{HERE} --without-memcached --disable-shared --disable-utils --disable-dependency-tracking #{$CC} #{$EXTRA_CONF} 2>&1", "Configuring libmemcached.")
    end

    Dir.chdir(BUNDLE_PATH) do
      #Running the make command in another script invoked by another shell command solves the "cd ." issue on FreeBSD 6+
      run("GMAKE_CMD='#{GMAKE_CMD}' CXXFLAGS='#{$CXXFLAGS} #{LIBM_CFLAGS}' SOURCE_DIR='#{BUNDLE_PATH}' HERE='#{HERE}' ruby ../extconf-make.rb", "Making libmemcached.")
    end
  end

  # Absolutely prevent the linker from picking up any other libmemcached
  Dir.chdir("#{HERE}/lib") do
    system("cp -f libmemcached.a libmemcached_gem.a")
    system("cp -f libmemcached.la libmemcached_gem.la")
  end
  $LIBS << " -lmemcached_gem -lsasl2"
end

check_libmemcached

if ENV['SWIG']
  puts "WARNING: Swig 2.0.2 not found. Other versions may not work." if (`swig -version`!~ /2.0.2/)
  run("swig #{$defines} #{$includes} -ruby -autorename -o rlibmemcached_wrap.c.in rlibmemcached.i", "Running SWIG.")
  swig_patches = {
    "STR2CSTR" => "StringValuePtr",                                # Patching SWIG output for Ruby 1.9.
    "\"swig_runtime_data\"" =>  "\"SwigRuntimeData\"",             # Patching SWIG output for Ruby 1.9.
    "#ifndef RUBY_INIT_STACK" => "#ifdef __NEVER__",               # Patching SWIG output for JRuby.
  }.map{|pair| "s/#{pair.join('/')}/"}.join(';')

  # sed has different syntax for inplace switch in BSD and GNU version, so using intermediate file
  run("sed '#{swig_patches}' rlibmemcached_wrap.c.in > rlibmemcached_wrap.c", "Apply patches to SWIG output")
end

$CFLAGS << " -Os"
create_makefile 'rlibmemcached'
run("mv Makefile Makefile.in", "Copy Makefile")
run("sed 's/-I.opt.local.include//' Makefile.in > Makefile", "Remove MacPorts from the include path")

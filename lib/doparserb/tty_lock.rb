# frozen_string_literal: true

require "tmpdir"

module Doparserb
  class TTYLock
    def initialize(output: $stderr, path: nil)
      stat = output.stat unless path
      @path = path || File.join(Dir.tmpdir, "doparserb-#{Process.uid}-tty-#{stat.dev}-#{stat.rdev}.lock")
    end

    def acquire(wait: false)
      @file = File.open(@path, File::RDWR | File::CREAT | File::NOFOLLOW, 0o600)
      acquired = !!@file.flock(wait ? File::LOCK_EX : File::LOCK_EX | File::LOCK_NB)
      close unless acquired
      acquired
    rescue SystemCallError, IOError => error
      Doparserb.debug(error)
      false
    end

    def close
      @file&.close
      @file = nil
    end
  end
end

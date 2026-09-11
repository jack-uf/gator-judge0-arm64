# Standalone check for Base64Service.
#
#   ruby checks/check_base64_service.rb
#
# The decoded text is what the verdict is computed from. If the decode rewrites
# bytes, two programs producing different output compare equal and the wrong
# answer is reported as Accepted.
require "base64"

ROOT = File.expand_path("..", __dir__)
require_relative "#{ROOT}/judge0-src/app/services/base64_service"

FAILURES = []

def check(condition, message)
  if condition
    puts "ok: #{message}"
  else
    FAILURES << message
    puts "FAIL: #{message}"
  end
end

def b64(bytes)
  Base64.strict_encode64(bytes)
end

# --- text still round-trips --------------------------------------------------
check Base64Service.decode(b64("hello")) == "hello", "ASCII survives the decode"
check Base64Service.decode(b64("cafe\u0301")) == "cafe\u0301", "combining marks survive"

# --- the verdict is computed on bytes, so bytes must not be rewritten --------
# Every byte that is not valid UTF-8 used to be replaced with "?", which made
# all of them equal to each other. A program printing 0xFE and one printing 0xFF
# produced the same string, so a wrong answer compared equal to the expected one.
expected = Base64Service.decode(b64("\xff".b))
actual = Base64Service.decode(b64("\xfe".b))
check !expected.nil? && !actual.nil?, "non-UTF-8 output decodes at all"
check expected != actual, "two different non-UTF-8 bytes do not decode equal"
check expected.bytes == [0xff], "the expected byte is preserved, not replaced"
check actual.bytes == [0xfe], "the produced byte is preserved, not replaced"
check !expected.include?("?"), "no replacement character is introduced"

# The comparison the worker actually performs, on the shape the worker actually
# has: expected output arrives as decoded bytes, program output arrives as raw
# bytes read from the sandbox's stdout file.
check Base64Service.decode(b64("\xff".b)) != "\xfe".b,
      "different bytes are a Wrong Answer, not an Accepted"
check Base64Service.decode(b64("\xff".b)) == "\xff".b,
      "identical bytes are still an Accepted"

# --- binary payloads are untouched -------------------------------------------
zip_head = "PK\x03\x04\xff\xfe\x00\x01".b
check Base64Service.decode_binary(b64(zip_head)).bytes == zip_head.bytes,
      "the binary path preserves every byte"

# --- absent values stay absent ----------------------------------------------
check Base64Service.decode(nil).nil?, "a nil stays nil"
check Base64Service.decode_binary(nil).nil?, "a nil binary stays nil"

if FAILURES.empty?
  puts "\nall base64 checks passed"
else
  puts "\n#{FAILURES.size} failure(s)"
  exit 1
end

#!/usr/bin/perl
# Redact high-entropy strings that look like passwords
# Called by sanitize-output.sh
#
# Looks for 8-32 char strings with uppercase, lowercase, digits, AND special chars
# These are likely passwords or API keys

use strict;
use warnings;

while (<STDIN>) {
    # Match strings after =, :, or " that look like credentials
    # Followed by whitespace, quote, or end of string
    s{
        ([=:"]\s*)                                    # prefix: =, :, or " plus optional space
        ([A-Za-z0-9!@\#\$%^&*()\[\]{}|;:<>,.?/_+="-]{8,32})  # the credential-like string
        (\s|[\"']|$)                                  # suffix: space, quote, or EOL
    }{
        my ($pre, $str, $post) = ($1, $2, $3);
        my $has_upper = ($str =~ /[A-Z]/);
        my $has_lower = ($str =~ /[a-z]/);
        my $has_digit = ($str =~ /[0-9]/);
        my $has_special = ($str =~ /[!@\#\$%^&*()\[\]{}|;:<>,.?\/_+=-]/);
        my $entropy = $has_upper + $has_lower + $has_digit + $has_special;

        if ($entropy >= 3) {
            "${pre}[REDACTED-CREDENTIAL]${post}"
        } else {
            "${pre}${str}${post}"
        }
    }gex;
    print;
}

#!/usr/bin/perl -w

########################################################################
# 2ping, a bi-directional ping utility
# Copyright (C) 2010 Ryan Finnie <ryan@finnie.org>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301, USA.
########################################################################

my $VERSION = '1.2.3';
my $EXTRAVERSION = '#EXTRAVERSION#';

use warnings;
use strict;
use Config;
use Getopt::Long;
use Pod::Usage;
use IO::Select;
use IO::Socket::INET;
use Time::HiRes qw/time/;
# IO::Socket::INET6 may be loaded below
# Digest::MD5 may be loaded below
# Digest::SHA may be loaded below
# Digest::CRC may be loaded below

# "use constant {}" doesn't seem available in Perl 5.6, everything else
# works in 5.6, so we may as well make it backwards compatible to that.
use constant OPCODE_SENDREPLY => 1;
use constant OPCODE_REPLYTO => 2;
use constant OPCODE_RTT => 4;
use constant OPCODE_LOSTFOUNDS => 8;
use constant OPCODE_LOSTNOTFOUNDS => 16;
use constant OPCODE_LOSTPACKETS => 32;
use constant OPCODE_COURTESIES => 64;
use constant OPCODE_HASH => 128;
use constant OPCODE_DELAY => 256;
use constant OPCODE_EXTENDED => 32768;
use constant EXTENDED_ID_VERSION => 0x3250564e;
use constant EXTENDED_ID_NOTICE => 0xa837b44e;
use constant LEN_MAGIC_NUMBER => 2;
use constant LEN_CHECKSUM => 2;
use constant LEN_MESSAGE_ID => 6;
use constant LEN_OPCODES => 2;
use constant LEN_OPCODE_HEADER_LEN => 2;
use constant LEN_ARRAY_CNT => 2;
use constant LEN_RTT => 4;
use constant LEN_DIGEST_TYPE => 2;
use constant LEN_DELAY => 4;
use constant LEN_EXTENDED_ID => 4;
use constant LEN_EXTENDED_LEN => 2;

my $versionstring = sprintf('2ping %s%s (%s)',
  $VERSION,
  ($EXTRAVERSION eq ('#'.'EXTRAVERSION'.'#') ? '' : $EXTRAVERSION),
  $Config{'archname'}
);

########################################################################
# Command line option parsing
########################################################################

my(
  $opt_ignoreopt,
  $opt_ignoreopt_val,
  $opt_help,
  $opt_listen,
  $opt_debug,
  $opt_interval,
  $opt_packetloss,
  $opt_inqwait,
  $opt_minpacket,
  $opt_maxpacket,
  $opt_port,
  $opt_ipv6,
  @opt_intaddrs,
  $opt_flood,
  $opt_audible,
  $opt_verbose,
  $opt_compat_packetsize,
  $opt_pad_pattern,
  $opt_quiet,
  $opt_version,
  $opt_adaptive,
  $opt_count,
  $opt_deadline,
  $opt_3way,
  $opt_preload,
  $opt_auth,
  $opt_authdigest,
  $opt_stats,
  $opt_notice,
  $opt_sendversion,
);

$opt_preload = 1;
$opt_sendversion = 1;
$opt_3way = 1;

Getopt::Long::Configure("bundling");
my($result) = GetOptions(
  'b|B|d|L|n|R|r|U' => \$opt_ignoreopt,
  'F|Q|S|t|T|M|W=s' => \$opt_ignoreopt_val,
  'a' => \$opt_audible,
  'A' => \$opt_adaptive,
  'c=i' => \$opt_count,
  'f' => \$opt_flood,
  'i=f' => \$opt_interval,
  'I=s' => \@opt_intaddrs,
  'l=i' => \$opt_preload,
  'p=s' => \$opt_pad_pattern,
  'q' => \$opt_quiet,
  's=i' => \$opt_compat_packetsize,
  'v' => \$opt_verbose,
  'V' => \$opt_version,
  'w=f' => \$opt_deadline,
  'help|?' => \$opt_help,
  'auth=s' => \$opt_auth,
  'auth-digest=s' => \$opt_authdigest,
  'debug' => \$opt_debug,
  'inquire-wait=f' => \$opt_inqwait,
  'ipv6|6' => \$opt_ipv6,
  'listen' => \$opt_listen,
  'min-packet-size=i' => \$opt_minpacket,
  'max-packet-size=i' => \$opt_maxpacket,
  '3way!' => \$opt_3way,
  'packet-loss=s' => \$opt_packetloss,
  'port=i' => \$opt_port,
  'stats=f' => \$opt_stats,
  'notice=s' => \$opt_notice,
  'send-version!' => \$opt_sendversion,
);

if($opt_version) {
  print "$versionstring\n";
  exit;
}

# If called as "2ping6", assume -6
if($0 =~ /[\/\\^]2ping6$/) {
  $opt_ipv6 = 1;
}

if(((scalar @ARGV == 0) && !$opt_listen) || $opt_help) {
  print STDERR "$versionstring\n";
  print STDERR "Copyright (C) 2010 Ryan Finnie <ryan\@finnie.org>\n";
  print STDERR "\n";
  pod2usage(2);
}

my($authhashf);
my($authhashint);
my($authhashlen);
if($opt_auth) {
  $opt_authdigest = 'hmac-md5' unless($opt_authdigest);
  unless(grep $_ eq $opt_authdigest, qw/hmac-md5 hmac-sha1 hmac-sha256 hmac-crc32/) {
    print STDERR "2ping: Invalid hash algorithm specified.  Valid alogorithms: hmac-md5 hmac-sha1 hmac-sha256 hmac-crc32\n";
    exit 2;
  }
  if($opt_authdigest eq "hmac-md5") {
    require Digest::MD5;
    $authhashf = \&Digest::MD5::md5;
    $authhashint = 1;
    $authhashlen = 16;
  } elsif($opt_authdigest eq "hmac-crc32") {
    require Digest::CRC;
    $authhashf = \&crc32_bin;
    $authhashint = 4;
    $authhashlen = 4;
  } else {
    require Digest::SHA;
    if($opt_authdigest eq "hmac-sha1") {
      $authhashf = \&Digest::SHA::sha1;
      $authhashint = 2;
      $authhashlen = 20;
    } elsif($opt_authdigest eq "hmac-sha256") {
      $authhashf = \&Digest::SHA::sha256;
      $authhashint = 3;
      $authhashlen = 32;
    }
  }
}

if(($opt_preload < 1) || ($opt_preload > 65536)) {
  print STDERR "2ping: bad preload value, should be 1..65536\n";
  exit 2;
}
if(($opt_preload > 3) && ($> > 0)) {
  print STDERR "2ping: cannot set preload to value > 3\n";
  exit 2;
}

# "Real flood" is sending as fast as possible.  If the user specified both
# flood and an interval, it's not really flood mode, just a shortened
# output mode.  Otherwise, send as fast as the replies come in, or 100
# times per second, whichever is greater.
my($opt_realflood) = 0;
if($opt_flood && !$opt_interval) {
  if($> > 0) {
    print STDERR "2ping: cannot flood; minimal interval, allowed for user, is 200ms\n";
    exit 2;
  }
  $opt_interval = 0.01;
  $opt_realflood = 1;
}
if($opt_adaptive && !$opt_interval && ($> > 0)) {
  $opt_interval = 0.2;
}

$opt_interval = 1 unless $opt_interval;
if(($> > 0) && ($opt_interval < 0.2)) {
  print STDERR "2ping: cannot flood; minimal interval, allowed for user, is 200ms\n";
  exit 2;
}
# Default time to wait before inquiring about lost packets.
$opt_inqwait = 10 unless $opt_inqwait;
# -s: ping compatibility.  Set $opt_minpacket to this plus 8.
$opt_minpacket = $opt_compat_packetsize + 8 if(!$opt_minpacket && $opt_compat_packetsize);
# Default minimum/maximum packet sizes.  Absolute minimum maximum (if that
# makes sense) is 64.
$opt_minpacket = 64 unless $opt_minpacket;
$opt_maxpacket = 512 unless $opt_maxpacket;
$opt_maxpacket = 64 if($opt_maxpacket < 64);
$opt_minpacket = $opt_maxpacket if($opt_minpacket > $opt_maxpacket);
# Default UDP port (IANA-registered port for 2ping)
$opt_port = 15998 unless $opt_port;

# Build a pad pattern from user input.
# This could probably be cleaned up.
my($pad_pattern);
if($opt_pad_pattern) {
  unless($opt_pad_pattern =~ /^[0-9A-Fa-f]+$/) {
    die("2ping: patterns must be specified as hex digits.\n");
  }
  my($i) = 0;
  my($pattern_in) = $opt_pad_pattern;
  while(length($pattern_in) > 0) {
    my($hexbyte);
    if(length($pattern_in) == 1) {
      $hexbyte = $pattern_in . '0';
      $pattern_in = '';
    } else {
      $hexbyte = substr($pattern_in, 0, 2);
      $pattern_in = substr($pattern_in, 2);
    }
    $pad_pattern .= chr(hex($hexbyte));
    $i++;
    last if $i == 16;
  }
}
if($pad_pattern) {
  printf("PATTERN: 0x%*v02x\n", '', $pad_pattern);
} else {
  $pad_pattern = chr(0);
}

# Config simulated packet loss.
my($opt_packetloss_out) = 0;
my($opt_packetloss_in) = 0;
if($opt_packetloss) {
  if($opt_packetloss =~ /^(\d+):(\d+)$/) {
    $opt_packetloss_out = $1;
    $opt_packetloss_in = $2;
  } elsif($opt_packetloss =~ /^(\d+)$/) {
    $opt_packetloss_out = $opt_packetloss;
    $opt_packetloss_in = $opt_packetloss;
  }
}

# Set up signals
$SIG{ALRM} = \&processsigalrm;
$SIG{INT} = \&processsigint;
$SIG{QUIT} = \&processsigquit;

########################################################################
# Global variables
########################################################################

# Script execution start time
my($starttime) = time;
# Incrementing index count, by peer session (ping_seq=1, etc)
my(%cntbypeer) = ();
# Total raw packets sent
my($packetsout) = 0;
# Total raw packets received
my($packetsin) = 0;
# Total ping requests sent
my($pingsout) = 0;
# Total ping requests received successfully
my($pingsin) = 0;
# Total errors (ICMP errors, invalid checksum, etc)
my($errors) = 0;
# RTT sum in ms ($pingsinrttsum / $pingsin = avg rtt)
my($pingsinrttsum) = 0;
# Sum of squares of RTTs, for quick stddev calculation
my($pingsinrttsumsq) = 0;
# Exponentially weighted moving average
my($pingsinewma) = 0;
# Maximum single RTT computed
my($pingsinrttmax) = 0;
# Minimum single RTT computed
my($pingsinrttmin) = 0;
# Confirmed outbound pings lost
my($outlost) = 0;
# Confirmed inbound pings lost
my($inlost) = 0;
# Sent message ID info hash that we expect replies to
my(%msginfo) = ();
# Received message ID info hash that we responded to
my(%msgreplyinfo) = ();
# IO::Socket objects
my(@socks);
# Last time %msginfo and %msgreplyinfo were cleaned up
my($lastcleanup) = time;
# Last time a packet was received
my($lastreply) = 0;
# Last time a scheduled interval was run (usually results in a new ping
# being sent, but may not in flood/adaptive mode)
my($lastsched) = time;
# Last time a stats line was printed
my($laststats) = time;

########################################################################
# Socket setup
########################################################################

# Many systems don't have IO::Socket::INET6, so don't try to load it
# unless needed.
if($opt_ipv6) {
  require IO::Socket::INET6;
}

# Turn off STDOUT buffering.
STDOUT->autoflush(1);

if($opt_listen) {
  my(@working_opt_intaddrs) = @opt_intaddrs;
  if((scalar @working_opt_intaddrs) == 0) {
    push(@working_opt_intaddrs, undef);
  }
  foreach my $opt_intaddr (@working_opt_intaddrs) {
    my($sock);
    my($is_ipv6) = $opt_ipv6;
    if($opt_ipv6 && $opt_intaddr =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
      $is_ipv6 = 0;
    }
    my $sockerr = '';
    my $sockaddlerr = '';
    if($is_ipv6) {
      $sock = IO::Socket::INET6->new(
        Domain => 10, # AF_INET6
        LocalAddr => ($opt_intaddr ? $opt_intaddr : undef),
        LocalPort => $opt_port,
        Proto => 'udp'
      );
      unless($sock) { $sockerr = $!; $sockaddlerr = $@; }
    } else {
      $sock = IO::Socket::INET->new(
        Domain => 2, # AF_INET
        LocalAddr => ($opt_intaddr ? $opt_intaddr : undef),
        LocalPort => $opt_port,
        Proto => 'udp'
      );
      unless($sock) { $sockerr = $!; $sockaddlerr = $@; }
    }
    die sprintf("Could not create socket: %s%s\n", $sockerr, ($sockaddlerr ? " ($sockaddlerr)" : "")) unless $sock;
    binmode($sock, ':raw');
    printf("2PING listener (%s): %d to %d bytes of data.\n", $sock->sockhost, $opt_minpacket, $opt_maxpacket);
    push(@socks, $sock);
  }
} else {
  my($opt_intaddr) = undef;
  if((scalar @opt_intaddrs) > 1) {
    $opt_intaddr = $opt_intaddrs[0];
  }
  foreach my $to (@ARGV) {
    my($sock);
    my($is_ipv6) = $opt_ipv6;
    # If -6 is specified and an IPv4-like argument is given, use the IPv4
    # stack instead.
    if($opt_ipv6 && $to =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
      $is_ipv6 = 0;
    }
    my $sockerr = '';
    my $sockaddlerr = '';
    if($is_ipv6) {
      $sock = IO::Socket::INET6->new(
        Domain => 10, # AF_INET6
        LocalAddr => ($opt_intaddr ? $opt_intaddr : undef),
        PeerPort  => $opt_port,
        PeerAddr  => $to,
        Proto     => 'udp',
      );
      unless($sock) { $sockerr = $!; $sockaddlerr = $@; }
    } else {
      $sock = IO::Socket::INET->new(
        Domain => 2, # AF_INET
        LocalAddr => ($opt_intaddr ? $opt_intaddr : undef),
        PeerPort  => $opt_port,
        PeerAddr  => $to,
        Proto     => 'udp',
      );
      unless($sock) { $sockerr = $!; $sockaddlerr = $@; }
    }
    die sprintf("Could not create socket: %s%s\n", $sockerr, ($sockaddlerr ? " ($sockaddlerr)" : "")) unless $sock;
    printf("2PING %s (%s): %d to %d bytes of data.\n", $to, $sock->peerhost, $opt_minpacket, $opt_maxpacket);
    binmode($sock, ':raw');
    push(@socks, $sock);

    my(%peer) = (
      'sock' => $sock,
    );
    $peer{'peerhost'} = $peer{'sock'}->peerhost;
    $peer{'peeraddr'} = $peer{'sock'}->peeraddr;
    $peer{'peerport'} = $peer{'sock'}->peerport;
    $peer{'peertuple'} = $peer{'sock'}->sockaddr . $peer{'sock'}->sockport . $peer{'sock'}->peeraddr . $peer{'sock'}->peerport . $peer{'sock'}->protocol;
    $peer{'peername'} = $peer{'sock'}->peername;

    # Immediately send a new ping to start out in client mode.
    for(my $i = 1; $i <= $opt_preload; $i++) {
      sendpacket(\%peer, 1);
    }
  }
}

########################################################################
# Main loop
########################################################################

my($iosel) = IO::Select->new();
foreach my $sock (@socks) {
  $iosel->add($sock);
}
while(1) {
  # Schedule the IO::Select timeout for either:
  #   Listener: Next cleanup time (every 60 seconds)
  #   Client: Next interval time (every second unless specified)
  my($now) = time;
  my($waittime);
  if($opt_listen) {
    $waittime = 60 - ($now - $lastcleanup);
  } else {
    $waittime = $opt_interval - ($now - $lastsched);
  }
  if($opt_stats) {
    my($waittime_stats) = $opt_stats - ($now - $laststats);
    $waittime = $waittime_stats if($waittime_stats < $waittime);
  }
  $waittime = 0 if($waittime < 0);
  my(@canread) = $iosel->can_read($waittime);
  foreach my $sock (@canread) {
    processincomingpacket($sock);
  }

  # We're in the timeout for whatever reason.  Do some housekeeping.

  # Cleanup occurs every 60 seconds.
  if(($now - $lastcleanup) >= 60) {
    debug("Cleanup run\n");
    # IDs we sent that have not been purged, and are older than 10
    # minutes should be purged.
    foreach my $testmsgid (keys %msginfo) {
      my $delta = $now - $msginfo{$testmsgid}->{'time'};
      debug(sprintf("  msginfo: %*v02x is %d sec old\n", '', $testmsgid, $delta));
      if($delta > 600) {
        debug(sprintf("msginfo: Deleting %*v02x (expired)\n", '', $testmsgid));
        delete($msginfo{$testmsgid});
      }
    }
    # IDs we replied to that are older than 2 minutes should be purged.
    foreach my $testmsgid (keys %msgreplyinfo) {
      my $delta = $now - $msgreplyinfo{$testmsgid}->{'time'};
      debug(sprintf("  msgreplyinfo: %*v02x is %d sec old\n", '', $testmsgid, $delta));
      if($delta > 120) {
        debug(sprintf("msgreplyinfo: Deleting %*v02x (expired)\n", '', $testmsgid));
        delete($msgreplyinfo{$testmsgid});
      }
    }
    $lastcleanup = $now;
  }

  # If we've reached the deadline (maximum program execution time),
  # go ahead and exit.
  if($opt_deadline && (($now - $starttime) >= $opt_deadline)) {
    gracefulexit();
  }

  # Print occasional stats if specified
  if($opt_stats && (($now - $laststats) >= $opt_stats)) {
    shortstats();
    $laststats = $now;
  }

  # Should we send a new ping?  Several ways this can happen:
  #   1. Normal mode, and interval has been reached.
  #   2. Flood mode, and interval (which most likely has been set very
  #      low because of flood mode) has passed without a reply.
  #   3. Adaptive mode, and interval has passed without a reply.
  if(!$opt_listen && (($now - $lastsched) >= $opt_interval)) {
    $lastsched = $now;
    if($opt_adaptive || $opt_realflood) {
      if(($now - $lastreply) > $opt_interval) {
        sendpacket_all();
      }
    } else {
      sendpacket_all();
    }
  }

}

# Take a socket (that we know is waiting by now), recv() it, send it on
# to be parsed, then process its logic.
sub processincomingpacket {
  my($payload);
  my($recvtime);
  my(%peer) = (
    'sock' => $_[0],
  );
  $packetsin++;
  if($peer{'sock'}->recv($payload, 16384)) {
    $recvtime = time;
    if(($opt_packetloss_in > 0) && (rand() < ($opt_packetloss_in / 100))) {
      return;
    }
    $lastreply = $recvtime;
  } else {
    return(parseerror(sprintf("From %s: %s\n", $peer{'sock'}->peerhost, $!)));
  }
  $peer{'peerhost'} = $peer{'sock'}->peerhost;
  $peer{'peeraddr'} = $peer{'sock'}->peeraddr;
  $peer{'peerport'} = $peer{'sock'}->peerport;
  $peer{'peertuple'} = $peer{'sock'}->sockaddr . $peer{'sock'}->sockport . $peer{'sock'}->peeraddr . $peer{'sock'}->peerport . $peer{'sock'}->protocol;
  $peer{'peername'} = $peer{'sock'}->peername;

  my($peerid, $peersendreply, $peerreplyto, $peerrtt, $peerresendsref, $peerresendsnotfoundref, $peeroldidsref, $peercourtesiesref, $peerdelay, $peerextoptionsref) = processpacket($payload, \%peer);
  return unless $peerid;
  my(@peerresendsnotfound) = @{$peerresendsnotfoundref};
  my(@peerresends) = @{$peerresendsref};
  my(@peeroldids) = @{$peeroldidsref};
  my(@peercourtesies) = @{$peercourtesiesref};
  my(%peerextoptions) = %{$peerextoptionsref};

  debug(sprintf("msginfo count: %d\n", scalar keys(%msginfo)));
  foreach my $i (keys %msginfo) {
    debug(sprintf("  %*v02x\n", '', $i));
  }
  debug(sprintf("msgreplyinfo count: %d\n", scalar keys(%msgreplyinfo)));
  foreach my $i (keys %msgreplyinfo) {
    debug(sprintf("  %*v02x\n", '', $i));
  }
  my(@resends);
  my(@resendsnotfound);
  if($peersendreply) {
    $msgreplyinfo{$peer{'peertuple'} . $peerid} = {
      'time' => time
    };

    if(scalar(@peeroldids) > 0) {
      foreach my $peeroldid (@peeroldids) {
        if($msgreplyinfo{$peer{'peertuple'} . $peeroldid}) {
          push(@resends, $peeroldid);
        } else {
          push(@resendsnotfound, $peeroldid);
        }
      }
    }
  }

  foreach my $peercourtesy (@peercourtesies) {
    if($msgreplyinfo{$peer{'peertuple'} . $peercourtesy}) {
      debug(sprintf("msgreplyinfo: Deleting %*v02x (courtesy)\n", '', ($peer{'peertuple'} . $peercourtesy)));
      delete($msgreplyinfo{$peer{'peertuple'} . $peercourtesy});
    }
  }
  if($peerreplyto && $msginfo{$peer{'peertuple'} . $peerreplyto}) {
    my(%thismsginfo) = %{$msginfo{$peer{'peertuple'} . $peerreplyto}};
    my($rtt) = (($recvtime - $thismsginfo{'time'}) * 1000);
    $msginfo{$peer{'peertuple'} . $peerreplyto}->{'courtesy'} = 1;

    # If they want a reply, send it as early as possible.
    if($peersendreply) {
      # If $peersendreply is set (and we already know $peerreplyto is
      # set), then we know the peer was the 2nd leg of a 3-way ping, and
      # is requesting the 3rd leg.  So we shouldn't expect a reply
      # ourselves.
      sendpacket(\%peer, 0, $peerid, $rtt, \@resends, \@resendsnotfound, $recvtime);
    }

    if(scalar(@peerresends) > 0) {
      foreach my $peerresend (@peerresends) {
        if($msginfo{$peer{'peertuple'} . $peerresend}) {
          if(!$opt_quiet) {
            if($opt_flood) {
              print "<";
            } else {
              printf("Lost inbound packet from %s: ping_seq=%d\n", $peer{'peerhost'}, $msginfo{$peer{'peertuple'} . $peerresend}->{'idx'});
            }
          }
          $inlost++;
          $msginfo{$peer{'peertuple'} . $peerresend}->{'courtesy'} = 1;
        }
      }
    }
    if(scalar(@peerresendsnotfound) > 0) {
      foreach my $peerresendnotfound (@peerresendsnotfound) {
        if($msginfo{$peer{'peertuple'} . $peerresendnotfound}) {
          if(!$opt_quiet) {
            if($opt_flood) {
              print ">";
            } else {
              printf("Lost outbound packet to %s: ping_seq=%d\n", $peer{'peerhost'}, $msginfo{$peer{'peertuple'} . $peerresendnotfound}->{'idx'});
            }
          }
          $outlost++;
          $msginfo{$peer{'peertuple'} . $peerresendnotfound}->{'courtesy'} = 1;
        }
      }
    }
    # If this is the third leg of a 3-way, we should be able to determine
    # if we don't need reply info anymore, and delete it.  If the peer is
    # sending courtesy info though, most likely it's already deleted.
    if($thismsginfo{'replyto'} && $msgreplyinfo{$peer{'peertuple'} . $thismsginfo{'replyto'}}) {
      debug(sprintf("msgreplyinfo: Deleting %*v02x\n", '', ($peer{'peertuple'} . $thismsginfo{'replyto'})));
      delete($msgreplyinfo{$peer{'peertuple'} . $thismsginfo{'replyto'}});
    }

    # Print the ping result
    if(!$opt_quiet) {
      if($opt_flood) {
        print chr(8) . ' ' . chr(8);
      } else {
        printf("%d bytes from %s: ping_seq=%d time=%0.03f ms%s%s\n",
          length($payload),
          $peer{'peerhost'},
          $thismsginfo{'idx'},
          $rtt,
          ($peerrtt ? sprintf(' peertime=%0.03f ms', $peerrtt) : ''),
          ($opt_audible ? chr(7) : '')
        );
        if($peerextoptions{'notice'}) {
          printf("  Peer notice: %s\n", $peerextoptions{'notice'});
        }
      }
    }
    $pingsinrttsum += $rtt;
    $pingsinrttsumsq += $rtt ** 2;
    $pingsinewma = ($pingsinewma ? ($pingsinewma + ($rtt - ($pingsinewma / 8))) : ($rtt * 8));
    $pingsinrttmax = $rtt if($rtt > $pingsinrttmax);
    $pingsinrttmin = $rtt if(($rtt < $pingsinrttmin) || !$pingsinrttmin);
    $pingsin++;

    # If it's an adaptive or flood ping, send a new ping out.
    if(!$opt_listen && (($opt_adaptive && ($> == 0)) || $opt_realflood)) {
      sendpacket(\%peer, 1);
    }
  } elsif($peersendreply) {
    # Peer has requested a reply.
    if($peerreplyto || (!$peerreplyto && !$opt_3way)) {
      # Send back a normal ping reply.
      # If $peerreplyto was set and it wasn't caught above, that must mean
      # we somehow didn't know info about the packet (old expired?).
      # Still, they requested a reply, so we must reply.
      # Either the peer's response was 2nd leg of a 3-way ping (it had a
      # reply-to), or it's the 1st leg of a ping and config explicitly
      # disables 3-way pings.  Either way, do not request a reply.
      sendpacket(\%peer, 0, $peerid, 0, \@resends, \@resendsnotfound, $recvtime);
    } else {
      # Request a reply, this was the 1st leg of a 3-way ping, which we
      # will continue to make a 2nd and request a 3rd.
      sendpacket(\%peer, 1, $peerid, 0, \@resends, \@resendsnotfound, $recvtime);
    }
  }
}

# In certain cases (scheduled times, SIGALRM, etc), we want to send out
# a ping to all sockets.  Loop through each socket entry and send out a
# ping.  Note: in listener mode, the last socket peer could be
# seconds/days/years old.  Oops.
sub sendpacket_all {
  foreach my $sock (@socks) {
    # Sockets in listener mode that haven't received a packet yet will
    # not have a peer definition, and can't send(), so ignore them.
    next unless $sock->peeraddr;
    my(%peer) = (
      'sock' => $sock,
    );
    $peer{'peerhost'} = $peer{'sock'}->peerhost;
    $peer{'peeraddr'} = $peer{'sock'}->peeraddr;
    $peer{'peerport'} = $peer{'sock'}->peerport;
    $peer{'peertuple'} = $peer{'sock'}->sockaddr . $peer{'sock'}->sockport . $peer{'sock'}->peeraddr . $peer{'sock'}->peerport . $peer{'sock'}->protocol;
    $peer{'peername'} = $peer{'sock'}->peername;
    sendpacket(\%peer, 1);
  }
}

# Build a 2ping packet and send it out
sub sendpacket {
  my %peer = %{$_[0]}; # Peer info object
  my $sendreply = $_[1]; # Whether the remote side should send a reply (true/false)
  my $replyto = $_[2]; # Message ID being replied to
  my $rtt = $_[3]; # RTT reported (3rd leg)
  my @resends = ($_[4] ? @{$_[4]} : ()); # List of investigated IDs (received)
  my @resendsnotfound = ($_[5] ? @{$_[5]} : ()); # List of investigated IDs (never received)
  my $recvtime = $_[6]; # Time the recv() happened

  # Generate a random message ID
  my($msgid) = '';
  for(my $i = 1; $i <= LEN_MESSAGE_ID; $i++) {
    $msgid .= chr(int(rand(256)));
  }

  # $outbuff: Opcode data area (everything between opcode flags and
  # padding, exclusive)
  my $outbuff = '';
  # %outbuffs: Opcode data area segments, indexed by opcode flag (used to
  # build $outbuff)
  my %outbuffs;
  # $outbufflen: Working length of what $outbuff will eventually be
  my $outbufflen;
  # $opcodeflags: 32-bit opcode flag area
  my $opcodeflags = 0;

  # If we're beyond the deadline or count period, only send the packet if
  # we're not expecting a reply back.
  if($opt_deadline && $sendreply && ((time - $starttime) >= $opt_deadline)) {
    gracefulexit();
  }
  if($opt_count && $sendreply && ($pingsout >= $opt_count)) {
    gracefulexit();
  }

  # $vbuff is a built verbose output line
  my($vbuff) = '';
  if($opt_verbose) {
    $vbuff = sprintf('msgid=%*v02x', '', $msgid);
  }

  # 128: MAC hashing
  # We want room for this as soon as possible, so we're doing it now.
  # The actual hash will be filled in at the end.
  if($opt_auth) {
    $opcodeflags |= OPCODE_HASH;
    $outbuffs{OPCODE_HASH()} = pack('n', $authhashlen + LEN_DIGEST_TYPE) . pack('n', $authhashint) . (chr(0) x $authhashlen);
    $outbufflen += LEN_OPCODE_HEADER_LEN + $authhashlen + LEN_DIGEST_TYPE;
  }

  # 1: Reply expected
  if($sendreply) {
    $opcodeflags |= OPCODE_SENDREPLY;
    $outbuffs{OPCODE_SENDREPLY()} = pack('n', 0);
    $outbufflen += LEN_OPCODE_HEADER_LEN;
    if($opt_verbose) {
      $vbuff .= ' sendreply=yes';
    }
  }

  # 2: Replying to this Message ID
  if($replyto) {
    $opcodeflags |= OPCODE_REPLYTO;
    $outbuffs{OPCODE_REPLYTO()} = pack('n', LEN_MESSAGE_ID) . $replyto;
    $outbufflen += LEN_OPCODE_HEADER_LEN + LEN_MESSAGE_ID;
    if($opt_verbose) {
      $vbuff .= sprintf(' replyto=%*v02x', '', $replyto);
    }
  }

  # 256: RTT delay
  if($recvtime) {
    $opcodeflags |= OPCODE_DELAY;
    $outbufflen += LEN_OPCODE_HEADER_LEN + LEN_DELAY;
  }

  # 4: RTT included (3rd leg)
  if($rtt) {
    $opcodeflags |= OPCODE_RTT;
    my($rttmicro) = int($rtt * 1000);
    $outbuffs{OPCODE_RTT()} = pack('n', LEN_RTT) . pack('N', $rttmicro);
    $outbufflen += LEN_OPCODE_HEADER_LEN + LEN_RTT;
    if($opt_verbose) {
      $vbuff .= sprintf(' rtt=%0.03f', $rtt);
    }
  }

  # 8: Investigation complete, found these IDs
  if((scalar(@resends) > 0) && ((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + LEN_MESSAGE_ID) <= $opt_maxpacket)) {
    my($tmpoutbuff) = '';
    $opcodeflags |= OPCODE_LOSTFOUNDS;
    my($cnt) = 0;
    foreach my $resend (@resends) {
      if((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + length($tmpoutbuff) + LEN_MESSAGE_ID) <= $opt_maxpacket) {
        $tmpoutbuff .= $resend;
        $cnt++;
        if($opt_verbose) {
          if($cnt == 1) {
            $vbuff .= sprintf(' invfound=%*v02x', '', $resend);
          } else {
            $vbuff .= sprintf(',%*v02x', '', $resend);
          }
        }
      }
    }
    $outbuffs{OPCODE_LOSTFOUNDS()} = pack('n', LEN_ARRAY_CNT + length($tmpoutbuff)) . pack('n', $cnt) . $tmpoutbuff;
    $outbufflen += LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + length($tmpoutbuff);
  }

  # 16: Investigation complete, didn't fing these IDs
  if((scalar(@resendsnotfound) > 0) && ((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + LEN_MESSAGE_ID) <= $opt_maxpacket)) {
    my($tmpoutbuff) = '';
    $opcodeflags |= OPCODE_LOSTNOTFOUNDS;
    my($cnt) = 0;
    foreach my $resendnotfound (@resendsnotfound) {
      if((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + length($tmpoutbuff) + LEN_MESSAGE_ID) <= $opt_maxpacket) {
        $tmpoutbuff .= $resendnotfound;
        $cnt++;
        if($opt_verbose) {
          if($cnt == 1) {
            $vbuff .= sprintf(' invnotfound=%*v02x', '', $resendnotfound);
          } else {
            $vbuff .= sprintf(',%*v02x', '', $resendnotfound);
          }
        }
      }
    }
    $outbuffs{OPCODE_LOSTNOTFOUNDS()} = pack('n', LEN_ARRAY_CNT + length($tmpoutbuff)) . pack('n', $cnt) . $tmpoutbuff;
    $outbufflen += LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + length($tmpoutbuff);
  }

  # 32: Investigation requests
  my(@validoldas) = ();
  if($sendreply && ((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT) <= $opt_maxpacket)) {
    foreach my $testmsgid (keys %msginfo) {
      next unless($msginfo{$testmsgid}->{'peer'} eq $peer{'peertuple'});
      next if($msginfo{$testmsgid}->{'courtesy'});
      if($msginfo{$testmsgid}->{'time'} < (time() - $opt_inqwait)) {
        push(@validoldas, $msginfo{$testmsgid}->{'id'});
      }
    }
  }
  if($sendreply && (scalar(@validoldas) > 0) && ((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + LEN_MESSAGE_ID) <= $opt_maxpacket)) {
    fisher_yates_shuffle(\@validoldas);
    my($tmpoutbuff) = '';
    $opcodeflags |= OPCODE_LOSTPACKETS;
    my($cnt) = 0;
    foreach my $olda (@validoldas) {
      if((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + length($tmpoutbuff) + LEN_MESSAGE_ID) <= $opt_maxpacket) {
        $tmpoutbuff .= $olda;
        $cnt++;
        if($opt_verbose) {
          if($cnt == 1) {
            $vbuff .= sprintf(' invreq=%*v02x', '', $olda);
          } else {
            $vbuff .= sprintf(',%*v02x', '', $olda);
          }
        }
      }
    }
    $outbuffs{OPCODE_LOSTPACKETS()} .= pack('n', LEN_ARRAY_CNT + length($tmpoutbuff)) . pack('n', $cnt) . $tmpoutbuff;
    $outbufflen += LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + length($tmpoutbuff);
  }

  # 64: Courtesies
  my(@courtesies) = ();
  if((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT) <= $opt_maxpacket) {
    foreach my $testmsgid (keys %msginfo) {
      next unless($msginfo{$testmsgid}->{'peer'} eq $peer{'peertuple'});
      next unless($msginfo{$testmsgid}->{'courtesy'});
      push(@courtesies, $msginfo{$testmsgid}->{'id'});
      debug(sprintf("msginfo: Deleting %*v02x (courtesy sent)\n", '', $testmsgid));
      delete($msginfo{$testmsgid});
    }
  }
  if((scalar(@courtesies) > 0) && ((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + LEN_MESSAGE_ID) <= $opt_maxpacket)) {
    my($tmpoutbuff) = '';
    $opcodeflags |= OPCODE_COURTESIES;
    my($cnt) = 0;
    foreach my $courtesy (@courtesies) {
      if((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + length($tmpoutbuff) + LEN_MESSAGE_ID) <= $opt_maxpacket) {
        $tmpoutbuff .= $courtesy;
        $cnt++;
        if($opt_verbose) {
          if($cnt == 1) {
            $vbuff .= sprintf(' courtesy=%*v02x', '', $courtesy);
          } else {
            $vbuff .= sprintf(',%*v02x', '', $courtesy);
          }
        }
      }
    }
    $outbuffs{OPCODE_COURTESIES()} .= pack('n', LEN_ARRAY_CNT + length($tmpoutbuff)) . pack('n', $cnt) . $tmpoutbuff;
    $outbufflen += LEN_OPCODE_HEADER_LEN + LEN_ARRAY_CNT + length($tmpoutbuff);
  }

  # Extended options.  Only build the opcode block if any extended
  # options are set.
  my($buildextended) = 0;
  my(%extendedout) = ();

  # Extended 0xa837b44e: Notice text
  if($opt_notice && ((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_EXTENDED_ID + LEN_EXTENDED_LEN + length($opt_notice)) <= $opt_maxpacket)) {
    $buildextended = 1;
    $extendedout{EXTENDED_ID_NOTICE()} = $opt_notice;
    $outbufflen += LEN_EXTENDED_ID + LEN_EXTENDED_LEN + length($opt_notice);
    $vbuff .= sprintf(' notice="%s"', $opt_notice);
  }

  # Extended 0x3250564e: Program version
  if($opt_sendversion && ((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen + LEN_OPCODE_HEADER_LEN + LEN_EXTENDED_ID + LEN_EXTENDED_LEN + length($versionstring)) <= $opt_maxpacket)) {
    $buildextended = 1;
    $extendedout{EXTENDED_ID_VERSION()} = $versionstring;
    $outbufflen += LEN_EXTENDED_ID + LEN_EXTENDED_LEN + length($versionstring);
    $vbuff .= sprintf(' version="%s"', $versionstring);
  }

  # If any extended options are set, build the opcode block.
  if($buildextended) {
    $opcodeflags |= OPCODE_EXTENDED;
    my $extendedoutbuff = '';
    foreach my $extid (sort { $a <=> $b } keys %extendedout) {
      $extendedoutbuff .= pack('N', $extid) . pack('n', length($extendedout{$extid})) . $extendedout{$extid};
    }
    $outbufflen += LEN_OPCODE_HEADER_LEN;
    $outbuffs{OPCODE_EXTENDED()} .= pack('n', length($extendedoutbuff)) . $extendedoutbuff;
    $vbuff .= ' extended=yes';
  }

  # If there is room left, build padding according to the pattern.
  my($outpad) = '';
  my($pad) = 0;
  if((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen) < $opt_minpacket) {
    $pad = ($opt_minpacket - ((LEN_MAGIC_NUMBER + LEN_CHECKSUM + LEN_MESSAGE_ID + LEN_OPCODES + $outbufflen)));
    $outpad = substr(($pad_pattern x int(($pad / length($pad_pattern)) + 1)), 0, $pad);
    if($opt_verbose) {
      $vbuff .= sprintf(' pad=%d', $pad);
    }
  }

  my($sendtime) = time;

  # If a delay is being sent, calculate it as late as possible here
  if($recvtime) {
    my($delaymicro) = ($sendtime - $recvtime) * 1000000;
    $outbuffs{OPCODE_DELAY()} = pack('n', LEN_DELAY) . pack('N', $delaymicro);
    if($opt_verbose) {
      $vbuff .= sprintf(' delay=%0.03f', $delaymicro/1000);
    }
  }

  my $hashpos;
  # Loop through %outbuffs in numeric (opcode) order, assembling $outbuff
  foreach my $i (sort { $a <=> $b } keys %outbuffs) {
    $outbuff .= $outbuffs{$i};
    # If this is the hash area, record it for later use
    if($i == OPCODE_HASH) {
      $hashpos = length($outbuff) - $authhashlen;
    }
  }

  # Build the hash
  if($opt_auth) {
    $outbuff =
      substr($outbuff, 0, $hashpos) .
      hmac($authhashf, '2P' . pack('n', 0) . $msgid . pack('n', $opcodeflags) . $outbuff . $outpad, $opt_auth) .
      substr($outbuff, $hashpos + $authhashlen);
  }

#  # Fuzzing test
#  my($fuzzdata) = pack('n', $opcodeflags) . $outbuff;
#  if(rand() >= .5) {
#    my($rpos) = int(rand(length($fuzzdata)));
#    $fuzzdata = substr($fuzzdata, 0, $rpos) . chr(ord(substr($fuzzdata, $rpos, 1)) ^ 2**int(rand(8))) . substr($fuzzdata, $rpos+1);
#  } else {
#    my($olen) = length($fuzzdata);
#    $fuzzdata = '';
#    for(my $i = 0; $i < $olen; $i++) {
#      $fuzzdata .= chr(int(rand(256)));
#    }
#  }
#  $opcodeflags = unpack('n', substr($fuzzdata, 0, 2));
#  $outbuff = substr($fuzzdata, 2);

  # Build a checksum
  my($checksum);
  $checksum = ip_checksum('2P' . pack('n', 0) . $msgid . pack('n', $opcodeflags) . $outbuff . $outpad, 1);
  if($opt_verbose) {
    $vbuff .= sprintf(' cksum=%04x', $checksum);
  }
  my($finalpkt) = '2P' . pack('n', $checksum) . $msgid . pack('n', $opcodeflags) . $outbuff . $outpad;

#  # Random checksum errors
#  if(rand() > .5) {
#    my($rpos) = int(rand(length($finalpkt)/2))*2;
#    $finalpkt = substr($finalpkt, 0, $rpos) . pack('n', abs(unpack('n', substr($finalpkt, $rpos, 2))-1)) . substr($finalpkt, $rpos+2);
#  }

  # Send it!  (Unless we're simulating packet loss)
  if(!(($opt_packetloss_out > 0) && (rand() < ($opt_packetloss_out / 100)))) {
    $peer{'sock'}->send($finalpkt, 0, $peer{'peername'});
  }
  $packetsout++;

  # If we're expecting a reply, record it for future use
  if($sendreply) {
    unless($cntbypeer{$peer{'peertuple'}}) {
      $cntbypeer{$peer{'peertuple'}} = 0;
    }
    $cntbypeer{$peer{'peertuple'}}++;
    $msginfo{$peer{'peertuple'} . $msgid} = {
      'id' => $msgid,
      'idx' => $cntbypeer{$peer{'peertuple'}},
      'peer' => $peer{'peertuple'},
      'time' => $sendtime,
      'replyto' => $replyto,
      'courtesy' => 0,
    };
  }

  debug(sprintf("Sent: %*v02x\n", ' ', $finalpkt));
  if($opt_verbose) {
    printf("SEND: %d bytes to %s:%s: %s\n", length($finalpkt), $peer{'sock'}->peerhost, $peer{'sock'}->peerport, $vbuff);
  }

  if($sendreply) {
    print '.' if($opt_flood && !$opt_quiet);
    $pingsout++;
  }

  return($msgid);
}

sub processpacket {
  my($payload) = $_[0];
  my(%peer) = %{$_[1]};
  my($payloadlen) = length($payload);

  debug(sprintf("Received: %*v02x\n", ' ', $payload));
  # $vbuff is a built verbose output line
  my($vbuff) = '';

  # Magic number
  my($pos) = 0;
  return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
    unless(readbytestest($payloadlen, $pos, LEN_MAGIC_NUMBER));
  my($magic) = substr($payload, $pos, LEN_MAGIC_NUMBER);
  $pos += LEN_MAGIC_NUMBER;
  unless($magic eq '2P') {
    return(parseerror(sprintf("Invalid magic number from %s: expected %*v02x, received %*v02x\n", $peer{'peerhost'}, '', '2P', '', $magic)));
  }

  # Checksum
  return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
    unless(readbytestest($payloadlen, $pos, LEN_CHECKSUM));
  my($payload_checksum) = unpack('n', substr($payload, $pos, LEN_CHECKSUM));
  $pos += LEN_CHECKSUM;
  $vbuff .= sprintf('cksum=%04x', $payload_checksum) if $opt_verbose;
  if($payload_checksum > 0) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos));
    my($test_checksum) = ip_checksum('2P' . pack('n', 0) . substr($payload, $pos), 1);
    unless($payload_checksum == $test_checksum) {
      return(parseerror(sprintf("Invalid checksum from %s: expected %04x, received %04x\n", $peer{'peerhost'}, $test_checksum, $payload_checksum)));
    }
  }

  # Message ID
  return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
    unless(readbytestest($payloadlen, $pos, LEN_MESSAGE_ID));
  my($peerid) = substr($payload, $pos, LEN_MESSAGE_ID);
  $pos += LEN_MESSAGE_ID;
  $vbuff .= sprintf(' msgid=%*v02x', '', $peerid) if $opt_verbose;
  return unless(length($peerid) == LEN_MESSAGE_ID);

  # Opcode flags
  return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
    unless(readbytestest($payloadlen, $pos, LEN_OPCODES));
  my($opcodeflags) = unpack('n', substr($payload, $pos, LEN_OPCODES));
  $pos += LEN_OPCODES;

  # Don't accept a packet if we were expecting a hash
  if($opt_auth && !($opcodeflags & OPCODE_HASH)) {
    return(parseerror(sprintf("Auth hash expected from %s but not found: msgid=%*v02x\n", $peer{'peerhost'}, '', $peerid)));
  }

  # 1: Peer reply expected
  my($peersendreply) = 0;
  if($opcodeflags & OPCODE_SENDREPLY) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    if($opblocklen > 0) {
      return(parseerror(sprintf("Packet error from %s found: SENDREPLY: length expected 0, received %d\n", $peer{'peerhost'}, $opblocklen)));
    }
    $peersendreply = 1;
    $vbuff .= ' sendreply=yes' if $opt_verbose;
  }

  # 2: Peer replying to this Message ID
  my($peerreplyto);
  if($opcodeflags & OPCODE_REPLYTO) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    unless($opblocklen == LEN_MESSAGE_ID) {
      return(parseerror(sprintf("Packet error from %s found: REPLYTO: length expected %d, received %d\n", $peer{'peerhost'}, LEN_MESSAGE_ID, $opblocklen)));
    }
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_MESSAGE_ID));
    $peerreplyto = substr($payload, $pos, LEN_MESSAGE_ID);
    $pos += LEN_MESSAGE_ID;
    $vbuff .= sprintf(' replyto=%*v02x', '', $peerreplyto) if $opt_verbose;
  }

  # 4: Peer RTT included (3rd leg)
  my($peerrtt);
  if($opcodeflags & OPCODE_RTT) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    unless($opblocklen == LEN_RTT) {
      return(parseerror(sprintf("Packet error from %s found: RTT: length expected %d, received %d\n", $peer{'peerhost'}, LEN_RTT, $opblocklen)));
    }
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_RTT));
    $peerrtt = unpack('N', substr($payload, $pos, LEN_RTT)) / 1000;
    $pos += LEN_RTT;
    $vbuff .= sprintf(' rtt=%0.03f', $peerrtt) if $opt_verbose;
  }

  # 8: Peer investigation complete, found these IDs
  my(@peerresends);
  if($opcodeflags & OPCODE_LOSTFOUNDS) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    if($opblocklen < LEN_ARRAY_CNT) {
      return(parseerror(sprintf("Packet error from %s found: LOSTFOUNDS: length expected >= %d, received %d\n", $peer{'peerhost'}, LEN_ARRAY_CNT, $opblocklen)));
    }
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_ARRAY_CNT));
    my($found) = unpack('n', substr($payload, $pos, LEN_ARRAY_CNT));
    $pos += LEN_ARRAY_CNT;
    unless($opblocklen == ((LEN_MESSAGE_ID * $found) + LEN_ARRAY_CNT)) {
      return(parseerror(sprintf("Packet error from %s found: LOSTFOUNDS: length expected %d, received %d\n", $peer{'peerhost'}, ((LEN_MESSAGE_ID * $found) + LEN_ARRAY_CNT), $opblocklen)));
    }
    for(my $mi = 0; $mi < $found; $mi++) {
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, LEN_MESSAGE_ID));
      my($peerresend) = substr($payload, $pos, LEN_MESSAGE_ID);
      push(@peerresends, $peerresend);
      $pos += LEN_MESSAGE_ID;
      if($opt_verbose) {
        if($mi == 0) {
          $vbuff .= sprintf(' invfound=%*v02x', '', $peerresend);
        } else {
          $vbuff .= sprintf(',%*v02x', '', $peerresend);
        }
      }
    }
  }

  # 16: Peer investigation complete, didn't fing these IDs
  my(@peerresendsnotfound);
  if($opcodeflags & OPCODE_LOSTNOTFOUNDS) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    if($opblocklen < LEN_ARRAY_CNT) {
      return(parseerror(sprintf("Packet error from %s found: LOSTNOTFOUNDS: length expected >= %d, received %d\n", $peer{'peerhost'}, LEN_ARRAY_CNT, $opblocklen)));
    }
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_ARRAY_CNT));
    my($found) = unpack('n', substr($payload, $pos, LEN_ARRAY_CNT));
    $pos += LEN_ARRAY_CNT;
    unless($opblocklen == ((LEN_MESSAGE_ID * $found) + LEN_ARRAY_CNT)) {
      return(parseerror(sprintf("Packet error from %s found: LOSTNOTFOUNDS: length expected %d, received %d\n", $peer{'peerhost'}, ((LEN_MESSAGE_ID * $found) + LEN_ARRAY_CNT), $opblocklen)));
    }
    for(my $mi = 0; $mi < $found; $mi++) {
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, LEN_MESSAGE_ID));
      my($peerresendnotfound) = substr($payload, $pos, LEN_MESSAGE_ID);
      push(@peerresendsnotfound, $peerresendnotfound);
      $pos += LEN_MESSAGE_ID;
      if($opt_verbose) {
        if($mi == 0) {
          $vbuff .= sprintf(' invnotfound=%*v02x', '', $peerresendnotfound);
        } else {
          $vbuff .= sprintf(',%*v02x', '', $peerresendnotfound);
        }
      }
    }
  }

  # 32: Peer investigation requests
  my(@peeroldids);
  if($opcodeflags & OPCODE_LOSTPACKETS) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    if($opblocklen < LEN_ARRAY_CNT) {
      return(parseerror(sprintf("Packet error from %s found: LOSTPACKETS: length expected >= %d, received %d\n", $peer{'peerhost'}, LEN_ARRAY_CNT, $opblocklen)));
    }
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_ARRAY_CNT));
    my($found) = unpack('n', substr($payload, $pos, LEN_ARRAY_CNT));
    $pos += LEN_ARRAY_CNT;
    unless($opblocklen == ((LEN_MESSAGE_ID * $found) + LEN_ARRAY_CNT)) {
      return(parseerror(sprintf("Packet error from %s found: LOSTPACKETS: length expected %d, received %d\n", $peer{'peerhost'}, ((LEN_MESSAGE_ID * $found) + LEN_ARRAY_CNT), $opblocklen)));
    }
    for(my $mi = 0; $mi < $found; $mi++) {
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, LEN_MESSAGE_ID));
      my($peeroldid) = substr($payload, $pos, LEN_MESSAGE_ID);
      push(@peeroldids, $peeroldid);
      $pos += LEN_MESSAGE_ID;
      if($opt_verbose) {
        if($mi == 0) {
          $vbuff .= sprintf(' invreq=%*v02x', '', $peeroldid);
        } else {
          $vbuff .= sprintf(',%*v02x', '', $peeroldid);
        }
      }
    }
  }

  # 64: Peer courtesies
  my(@peercourtesies);
  if($opcodeflags & OPCODE_COURTESIES) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    if($opblocklen < LEN_ARRAY_CNT) {
      return(parseerror(sprintf("Packet error from %s found: COURTESIES: length expected >= %d, received %d\n", $peer{'peerhost'}, LEN_ARRAY_CNT, $opblocklen)));
    }
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_ARRAY_CNT));
    my($found) = unpack('n', substr($payload, $pos, LEN_ARRAY_CNT));
    $pos += LEN_ARRAY_CNT;
    unless($opblocklen == ((LEN_MESSAGE_ID * $found) + LEN_ARRAY_CNT)) {
      return(parseerror(sprintf("Packet error from %s found: COURTESIES: length expected %d, received %d\n", $peer{'peerhost'}, ((LEN_MESSAGE_ID * $found) + LEN_ARRAY_CNT), $opblocklen)));
    }
    for(my $mi = 0; $mi < $found; $mi++) {
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, LEN_MESSAGE_ID));
      my($peercourtesy) = substr($payload, $pos, LEN_MESSAGE_ID);
      push(@peercourtesies, $peercourtesy);
      $pos += LEN_MESSAGE_ID;
      if($opt_verbose) {
        if($mi == 0) {
          $vbuff .= sprintf(' courtesy=%*v02x', '', $peercourtesy);
        } else {
          $vbuff .= sprintf(',%*v02x', '', $peercourtesy);
        }
      }
    }
  }

  # 128: Peer MAC hashing
  if($opcodeflags & OPCODE_HASH) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    if($opt_auth) {
      if($opblocklen < LEN_DIGEST_TYPE) {
        return(parseerror(sprintf("Packet error from %s found: HASH: length expected >= %d, received %d\n", $peer{'peerhost'}, LEN_ARRAY_CNT, $opblocklen)));
      }
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, LEN_DIGEST_TYPE));
      my($digesttype) = unpack('n', substr($payload, $pos, LEN_DIGEST_TYPE));
      $pos += LEN_DIGEST_TYPE;
      unless($digesttype == $authhashint) {
        return(parseerror(sprintf("Hash digest mismatch from %s\n", $peer{'peerhost'})));
      }
      my($hashpos) = $pos;
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, $authhashlen));
      my($payload_hash) = substr($payload, $pos, $authhashlen);
      $pos += $authhashlen;
      $vbuff .= sprintf(' hash=%*v02x', '', $payload_hash) if $opt_verbose;
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, (LEN_MAGIC_NUMBER + LEN_DIGEST_TYPE), ($hashpos - (LEN_MAGIC_NUMBER + LEN_DIGEST_TYPE))));
      my($test_hash) = hmac($authhashf, '2P' . pack('n', 0) . substr($payload, (LEN_MAGIC_NUMBER + LEN_DIGEST_TYPE), ($hashpos - (LEN_MAGIC_NUMBER + LEN_DIGEST_TYPE))) . (chr(0) x $authhashlen) . substr($payload, $pos), $opt_auth);
      unless($payload_hash eq $test_hash) {
        return(parseerror(sprintf("Invalid hash from %s: expected %*v02x, received %*v02x\n", $peer{'peerhost'}, '', $test_hash, '', $payload_hash)));
      }
    } else {
      $pos += $opblocklen;
    }
  }

  # 256: Peer RTT delay
  my($peerdelay);
  if($opcodeflags & OPCODE_DELAY) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    unless($opblocklen == LEN_DELAY) {
      return(parseerror(sprintf("Packet error from %s found: DELAY: length expected %d, received %d\n", $peer{'peerhost'}, LEN_DELAY, $opblocklen)));
    }
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_DELAY));
    $peerdelay = unpack('N', substr($payload, $pos, LEN_DELAY)) / 1000;
    $pos += LEN_DELAY;
    $vbuff .= sprintf(' delay=%0.03f', $peerdelay) if $opt_verbose;
  }

  # Skip over unknown (undefined at the time of this writing) opcodes
  foreach my $unknownflag (qw/512 1024 2048 4096 8192 16384/) {
    if($opcodeflags & $unknownflag) {
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
      my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
      $pos += LEN_OPCODE_HEADER_LEN;
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, $opblocklen));
      $pos += $opblocklen;
      $vbuff .= sprintf(' unknown_opcode(%04x)=%dB', $unknownflag, $opblocklen) if $opt_verbose;
    }
  }

  # 32768: Extended format
  my %extoptions = ();
  if($opcodeflags & OPCODE_EXTENDED) {
    return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
      unless(readbytestest($payloadlen, $pos, LEN_OPCODE_HEADER_LEN));
    $vbuff .= ' extended=yes';
    my($opblockpos) = 0;
    my($opblocklen) = unpack('n', substr($payload, $pos, LEN_OPCODE_HEADER_LEN));
    $pos += LEN_OPCODE_HEADER_LEN;
    while($opblockpos < $opblocklen) {
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, LEN_EXTENDED_ID));
      my($extid) = unpack('N', substr($payload, $pos, LEN_EXTENDED_ID));
      $pos += LEN_EXTENDED_ID;
      $opblockpos += LEN_EXTENDED_ID;
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, LEN_EXTENDED_LEN));
      my($extlen) = unpack('n', substr($payload, $pos, LEN_EXTENDED_LEN));
      $pos += LEN_EXTENDED_LEN;
      $opblockpos += LEN_EXTENDED_LEN;
      return(parseerror(sprintf("Packet received from %s: attempt to read beyond packet\n", $peer{'peerhost'})))
        unless(readbytestest($payloadlen, $pos, $extlen));
      if($extid == EXTENDED_ID_VERSION) {
        my($extdata) = substr($payload, $pos, $extlen);
        $pos += $extlen;
        $opblockpos += $extlen;
        $vbuff .= sprintf(' version="%s"', $extdata) if $opt_verbose;
      } elsif($extid == EXTENDED_ID_NOTICE) {
        my($extdata) = substr($payload, $pos, $extlen);
        $pos += $extlen;
        $opblockpos += $extlen;
        $vbuff .= sprintf(' notice="%s"', $extdata) if $opt_verbose;
        $extoptions{'notice'} = $extdata;
      } else {
        $pos += $extlen;
        $opblockpos += $extlen;
        $vbuff .= sprintf(' unknown_ext(%08x)=%dB', $extid, $extlen) if $opt_verbose;
      }
    }
  }

  # Peer padding
  $vbuff .= sprintf(' pad=%d', (length($payload) - $pos)) if $opt_verbose;

  if($opt_verbose) {
    printf("RECV: %d bytes from %s:%s: %s\n", length($payload), $peer{'peerhost'}, $peer{'peerport'}, $vbuff);
  }
  return($peerid, $peersendreply, $peerreplyto, $peerrtt, \@peerresends, \@peerresendsnotfound, \@peeroldids, \@peercourtesies, $peerdelay, \%extoptions);
}

# Test for reading beyond the end of the packet
sub readbytestest {
  my($packetlen) = shift;
  my($pos) = shift;
  my($readlen) = shift;
  if(defined $readlen) {
    if(($pos + $readlen) > $packetlen) {
      return(0);
    }
    return(1);
  } else {
    if($pos > $packetlen) {
      return(0);
    }
    return(1);
  }
}

# Process a packet error
sub parseerror {
  my($msg) = shift;
  if(!$opt_quiet) {
    if($opt_flood) {
      print "E";
    } else {
      print $msg;
    }
  }
  $errors++;
  return;
}

# Print statistics and exit
sub gracefulexit {
  print "\n";
  printf("--- %s 2ping statistics ---\n", ($opt_listen ? 'Listener' : $ARGV[0]));
  printf(
    "%d pings transmitted, %d received,%s %d%% ping loss, time %dms\n",
    $pingsout,
    $pingsin,
    (($errors > 0) ? sprintf(' +%d errors,', $errors) : ''),
    lazydiv(($pingsout-$pingsin), $pingsout)*100,
    (time-$starttime)*1000
  );
  printf(
    "%d outbound ping losses (%d%%), %d inbound (%d%%), %d undetermined (%d%%)\n",
    $outlost,
    lazydiv($outlost, $pingsout)*100,
    $inlost,
    lazydiv($inlost, $pingsout)*100,
    $pingsout-$pingsin-$outlost-$inlost,
    lazydiv(($pingsout-$pingsin-$outlost-$inlost), $pingsout)*100
  );
  printf(
    "rtt min/avg/ewma/max/mdev = %0.03f/%0.03f/%0.03f/%0.03f/%0.03f ms\n",
    $pingsinrttmin,
    lazydiv($pingsinrttsum, $pingsin),
    $pingsinewma / 8,
    $pingsinrttmax,
    sqrt(lazydiv($pingsinrttsumsq, $pingsin) - (lazydiv($pingsinrttsum, $pingsin) ** 2))
  );
  printf("%d raw packets transmitted, %d received\n", $packetsout, $packetsin);
  exit(0);
}

# ALRM - manually sends a new ping
sub processsigalrm {
  # Really ALRM shouldn't be allowed in listener mode since it sends an
  # outgoing packet to whoever the last peer happened to be (if any at
  # all), but it's useful in debugging.
  sendpacket_all();
}

# INT - exits with summary
sub processsigint {
  gracefulexit();
}

# QUIT - doesn't actually quit, prints a 1-line summary
sub processsigquit {
  shortstats();
}

# Print one line of statistics without exiting
sub shortstats {
  printf("%d/%d pings, %d%% loss (%d/%d/%d out/in/undet), min/avg/max/ewma/mdev = %0.03f/%0.03f/%0.03f/%0.03f/%0.03f ms\n",
    $pingsout,
    $pingsin,
    lazydiv(($pingsout-$pingsin), $pingsout)*100,
    $outlost,
    $inlost,
    $pingsout-$pingsin-$outlost-$inlost,
    $pingsinrttmin,
    lazydiv($pingsinrttsum, $pingsin),
    $pingsinewma / 8,
    $pingsinrttmax,
    sqrt(lazydiv($pingsinrttsumsq, $pingsin) - (lazydiv($pingsinrttsum, $pingsin) ** 2))
  );
}

# Output text only if $opt_debug is on
sub debug {
  if($opt_debug) {
    my $msg = shift;
    print("DEBUG: $msg");
  }
}

# Division, replacing divide-by-zero with zero
sub lazydiv {
  my($a) = shift;
  my($b) = shift;
  return 0 if($b == 0);
  return($a / $b)
}

# fisher_yates_shuffle( \@array ) : generate a random permutation
# of @array in place
sub fisher_yates_shuffle {
    my $array = shift;
    my $i;
    for ($i = @$array; --$i; ) {
        my $j = int rand ($i+1);
        next if $i == $j;
        @$array[$i,$j] = @$array[$j,$i];
    }
}

# Generate a IP-style checksum of a packet, with an optional
# UDP-style mode adjustment.
sub ip_checksum {
  my($d) = shift; # Data
  my($rfc768) = shift; # RFC768 mode
  my($checksum) = 0;
  my($l) = length($d);

  # Input size is calculated on an even number.
  if($l % 2) {
    $l++;
    $d .= chr(0);
  }

  # Add the value of the packet.
  for(my $i = 0; $i < $l; $i += 2) {
    $checksum += unpack('n', substr($d, $i, 2));
  }

  # To avoid overloading 32 bits on $checksum, you should limit the
  # packet to 16MiB.  If this is not possible (flying car IPv6 future?),
  # you should check for large values within the loop above and
  # end-around carry as needed.
  $checksum = ($checksum >> 16) + ($checksum & 0xffff);

  # Calculate the ones' complement.
  $checksum = ~(($checksum >> 16) + $checksum) & 0xffff;

  # RFC768 mode: if the end result is zero, set to all ones per RFC768.
  # (UDPv4 checksum is optional, and lack of a checksum is signified by
  # zero value.  Checksums are required in IP (header), TCP, and UDPv6.)
  $checksum = 0xffff if(($checksum == 0) && $rfc768);

  return($checksum);
}

# Generate an HMAC hash
sub hmac {
  my($f) = shift;
  my($message) = shift;
  my($key) = shift;
  my($blocksize) = shift || 64;

  $key = &$f($key) if(length($key) > $blocksize);
  $key .= (chr(0) x ($blocksize - length($key))) if(length($key) < $blocksize);

  my($o_key_pad) = $key ^ (chr(0x5c) x $blocksize);
  my($i_key_pad) = $key ^ (chr(0x36) x $blocksize);

  return &$f($o_key_pad . &$f($i_key_pad . $message));
}

# Generate a binary CRC32 checksum (Digest::CRC::crc32 outputs an int)
sub crc32_bin {
  my($data) = shift;
  return pack('N', Digest::CRC::crc32($data));
}

sub resolve_host {
  my $inname = shift;
  my $is_ipv6 = shift;

  if($is_ipv6) {

  } else {
    my($name, $aliases, $addrtype, $length, @addrs)
  }
}

__END__

=head1 NAME

2ping - A bi-directional ping client/listener

=head1 SYNOPSIS

B<2ping> S<[ B<options> ]> S<B<--listen> | I<host/IP>>

=head1 DESCRIPTION

B<2ping> is a bi-directional ping utility.  It uses 3-way pings (akin to 
TCP SYN, SYN/ACK, ACK) and after-the-fact state comparison between a 
2ping listener and a 2ping client to determine which direction 
packet loss occurs.

To use 2ping, start a listener on a known stable network host.  The 
relative network stability of the 2ping listener host should not be in 
question, because while 2ping can determine whether packet loss is 
occurring inbound or outbound relative to an endpoint, that will not 
help you determine the cause if both of the endpoints are in question.

Once the listener is started, start 2ping in client mode and tell it to 
connect to the listener.  The ends will begin pinging each other and 
displaying network statistics.  If packet loss occurs, 2ping will wait a 
few seconds (default 10, configurable with -w) before comparing notes 
between the two endpoints to determine which direction the packet loss 
is occurring.

To quit 2ping on the client or listener ends, enter ^C, and a list of 
statistics will be displayed.  To get a short inline display of 
statistics without quitting, send the process a QUIT signal (yes, that's 
the opposite of what you would think, but it's in line with the normal 
ping utility).

=head1 OPTIONS

B<ping>-compatible options:

=over

=item B<-a>

Audible ping.

=item B<-A>

Adaptive ping.  A new client ping request is sent as soon as a client ping response is received.  If a ping response is not received within the interval period, a new ping request is sent.  Minimal interval is 200msec for not super-user.  On networks with low rtt this mode is essentially equivalent to flood mode.

B<2ping>-specific notes: This behavior is somewhat different to the nature of B<ping>'s adaptive ping, but the result is roughly the same.

=item B<-c> I<count>

Stop after sending I<count> ping requests.

B<2ping>-specific notes: This option behaves slightly differently from B<ping>.  If both B<-c> and B<-w> are specified, satisfaction of B<-c> will cause an exit first.  Also, internally, B<2ping> exits just before sending I<count>+1 pings, to give time for the ping to complete.

=item B<-f>

Flood ping. For every ping sent a period "." is printed, while for ever ping received a backspace is printed. This provides a rapid display of how many pings are being dropped.  If interval is not given, it sets interval to zero and outputs pings as fast as they come back or one hundred times per second, whichever is more.  Only the super-user may use this option with zero interval.

B<2ping>-specific notes: Detected outbound/inbound loss responses are printed as ">" and "<", respectively.  Receive errors are printed as "E".  Due to the asynchronous nature of B<2ping>, successful responses (backspaces) may overwrite these loss and error characters.

=item B<-i> I<interval>

Wait I<interval> seconds between sending each ping.  The default is to wait for one second between each ping normally, or not to wait in flood mode.  Only super-user may set interval to values less 0.2 seconds.

=item B<-I> I<interface IP>

Set source IP address.  When pinging IPv6 link-local address this option is required.  When in listener mode, this option may be specified multiple to bind to multiple IP addresses.  When in client mode, this option may only be specified once, and all outbound pings will be bound to this source IP.

B<2ping>-specific notes: This option only takes an IP address, not a device name.  Note that in listener mode, if the machine has an interface with multiple IP addresses and an request comes in via a sub IP, the reply still leaves via the interface's main IP.  So this option must be used if you would like to respond via an interface's sub-IP.

=item B<-l> I<preload>

If I<preload> is specified, B<2ping> sends that many packets not waiting for reply.  Only the super-user may select preload more than 3.

=item B<-p> I<pattern>

You may specify up to 16 "pad" bytes to fill out the packets you send.  This is useful for diagnosing data-dependent problems in a network.  For example, B<-p ff> will cause the sent packet pad area to be filled with all ones.

B<2ping>-specific notes: This pads the portion of the packet that does not contain the active payload data.  If the active payload data is larger than the minimum packet size (B<--min-packet-size>=I<min>), no padding will be sent.

=item B<-q>

Quiet output.  Nothing is displayed except the summary lines at startup time and when finished.

=item B<-s> I<packetsize>

B<ping> compatibility, this will set B<--min-packet-size> to this plus 8 bytes.

=item B<-v>

Verbose output.  In B<2ping>, this prints decodes of packets that are sent and received.

=item B<-V>

Show version and exit.

=item B<-w> I<deadline>

Specify a timeout, in seconds, before B<2ping> exits regardless of how many pings have been sent or received.  Due to blocking, this may occur up to one second after the deadline specified.

B<2ping>-specific notes: This option behaves slightly differently from B<ping>.  If both B<-c> and B<-w> are specified, satisfaction of B<-c> will cause an exit first.

=back

B<2ping>-specific options:

=over

=item B<-?>, B<--help>

Print a synposis and exit.

=item B<-6>, B<--ipv6>

Bind/connect as IPv6.

=item B<--auth>=I<key>

Set a shared key, send cryptographic hashes with each packet, and require cryptographic hashes from peer packets signed with the same shared key.

=item B<--auth-digest>=I<digest>

When B<--auth> is used, specify the digest type to compute the cryptographic hash.  Valid options are B<hmac-md5> (default), B<hmac-sha1> and B<hmac-sha256>.  hmac-md5 requires B<Digest::MD5>, and the SHA digests require B<Digest::SHA>.

=item B<--debug>

Print (lots of) debugging information.

=item B<--inquire-wait>=I<secs>

Wait at least I<secs> seconds before inquiring about a lost packet.  Default is 10 seconds.  UDP packets can arrive delayed or out of order, so it is best to give it some time before inquiring about a lost packet.

=item B<--listen>

Start as a listener.  The listener will not send out ping requests at regular intervals, and will instead wait for the far end to initiate ping requests.  A listener is required as the remote end for a client.

=item B<--min-packet-size>=I<min>

Set the minimum total payload size to I<min> bytes, default 64.  If the payload is smaller than I<min> bytes, padding will be added to the end of the packet.

=item B<--max-packet-size>=I<max>

Set the maximum total payload size to I<max> bytes, default 512, absolute minimum 64.  If the payload is larger than I<max> bytes, information will be rearranged and sent in future packets when possible.

=item B<--no-3way>

Do not perform 3-way pings.  Used most often when combined with B<--listen>, as the listener is usually the one to determine whether a ping reply should become a 3-way ping.

Strictly speaking, a 3-way ping is not necessary for determining directional packet loss between the client and the listener.  However, the extra leg of the 3-way ping allows for extra chances to determine packet loss more efficiently.  Also, with 3-way ping disabled, the listener will receive no client performance indicators, nor will the listener be able to determine directional packet loss that it detects.

=item B<--no-send-version>

Do not send the current running version of 2ping with each packet.

=item B<--notice>=I<text>

Arbitrary notice text to send with each packet.  If the remote peer supports it, this may be displayed to the user.

=item B<--packet-loss>=I<out:in>

Simulate random packet loss outbound and inbound.  For example, I<25:10> means a 25% chance of not sending a packet, and a 10% chance of ignoring a received packet.  A single number without colon separation means use the same percentage for both outbound and inbound.

=item B<--port>=I<port>

Use UDP port I<port>.  With B<--listen>, this is the port to bind as, otherwise this is the port to send to.  Default is UDP port 15998.

=item B<--stats>=I<interval>

Print a line of brief current statistics every I<interval> seconds.  The same line can be printed on demand by sending SIGQUIT to the 2ping process.

=back

=head1 BUGS

There are probably lots and lots and lots of unknown bugs.

By default, source IP logic doesn't work as expected, see B<-I> for details.  There appears to be no way to peg the source IP of reply UDP packets to the destination of the packet that is being replied to.  As a result, packets always go out the interface's main IP address if not specified manually.  (Please, prove the author wrong.)

This manpage isn't finished yet, and may never be.

=head1 AUTHOR

B<2ping> was written by Ryan Finnie <ryan@finnie.org>.

=cut
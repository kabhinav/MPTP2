#!/usr/bin/perl -w
$|++;
=head1 NAME

advisor.pl (Server translating Mizar symbols to numbers, talking to snow)

=head1 SYNOPSIS

advisor.pl [options] filestem

advisor.pl -s/home/urban/bin/snow -p50000 -a60000 /usr/local/share/mpadata/mpa1

 Options:
   --snowpath=<arg>,        -s<arg>
   --snowport=<arg>,        -p<arg>
   --advport=<arg>,         -a<arg>
   --symoffset=<arg>,       -o<arg>
   --limittargets=<arg>,    -L<arg>
   --snowserver=<arg>,      -W<arg>
   --help,                  -h
   --man

=head1 OPTIONS

=over 8

=item B<<< --snowpath=<arg>, -s<arg> >>>

Start the Snow binary at this path. If not given, only try
to connect to already running Snow.

=item B<<< --snowport=<arg>, -p<arg> >>>

The port for communiacting with Snow, default is 50000.

=item B<<< --advport=<arg>, -p<arg> >>>

The port for communiacting with advisor, default is 60000.

=item B<<< --symoffset=<arg>, -o<arg> >>>

The offset where symbol numbering starts. Has to correspond
to the one use for training the net.

=item B<<< --snowserver=<arg>, -B<W><arg> >>>

If 1, snow not started but run as daemon on snowport.
If 2, snow run over pipe and started inside this.
Default is 1.

=item B<<< --help, -h >>>

Print a brief help message and exit.

=item B<<< --man >>>

Print the manual page and exit.

=back

=head1 DESCRIPTION

B<advisor.pl> is a server translating Mizar symbol
(or rather constructor) queries to the number representation
loaded into the Snow server, and translating the Snow results
back to Mizar references. This is done according to the
symbol2number (.symnr) and ref2number (.refnr) tables
generated by MPTPMakeSnowDB.pl, and loaded from <filestem>.
These tables can be quite large (about 50000 entries),
so it is impractical to load them for each instance of
a cgi request separately.

=head1 CONTACT

Josef Urban urban@kti.ms.mff.cuni.cz

=cut

use strict;
use Pod::Usage;
use Getopt::Long;
use IO::Socket;
use IPC::Open2;

my (%gsyms,$grefs,$client);
my %grefnr;     # Ref2Nr hash for references
my @gnrref;     # Nr2Ref array for references

my %gsymnr;   # Sym2Nr hash for symbols
my @gnrsym;   # Nr2Sym array for symbols - takes gsymoffset into account!

my ($gpathtosnow,$snowport,$gport,$gsymoffset,$glimittargets,$gsnowserver,$giterrecover);
my ($help, $man);
Getopt::Long::Configure ("bundling");

GetOptions('snowpath|s=s'    => \$gpathtosnow,
	   'snowport|p=i'    => \$snowport,
	   'advport|a=i'     => \$gport,
	   'symoffset|o=i'   => \$gsymoffset,
	   'limittargets|L=i' => \$glimittargets,
	   'snowserver|W=i'    => \$gsnowserver,
	   'iterrecover|I=i' => \$giterrecover,
	   'help|h'          => \$help,
	   'man'             => \$man)
    or pod2usage(2);

pod2usage(1) if($help);
pod2usage(-exitstatus => 0, -verbose => 2) if($man);

pod2usage(2) if ($#ARGV != 0);

my $filestem   = shift(@ARGV);

$gport      = 60000 unless(defined($gport));
$snowport   = 50000 unless(defined($snowport));
$glimittargets = 0 unless(defined($glimittargets));
$gsnowserver = 1 unless(defined($gsnowserver));
$gpathtosnow = "/home/urban/ec/Snow_v3.2/snow" unless(defined($gpathtosnow));
$giterrecover = -1 unless(defined($giterrecover));

my $gtargetsnr;
my $gwantednr;

# offset at which symbol numbering starts -
# this depends on the params used for learning!
$gsymoffset = 500000 unless(defined($gsymoffset));;


sub min { my ($x,$y) = @_; ($x <= $y)? $x : $y }

# change for verbose logging
sub LOGGING { 1 };
sub LOGADVIO { 1 };
sub LOGSNIO { 2 };
sub LOGFLAGS { LOGADVIO | LOGSNIO };

my $gsnowpid;

sub StartSnow
{
    my ($iter,$wantednr) = @_;
    my $net = ($iter < 0)? 'net': "net_$iter";

    my $snowpid = open2(*SNOWREADER,*SNOWWRITER,"$gpathtosnow -test  -I /dev/stdin  -o allpredictions -F $filestem.$net -L $wantednr -B :0-$gtargetsnr|tee $filestem.snow_out");

    while (<SNOWREADER>)
    {
	print $_ if (LOGGING);
	last if /^Naive/;
    }

    return $snowpid;
}

# initializes also $gtargetsnr
sub StartServer
{    
    my ($iter) = @_;
    my $i = 0;

    open(REFNR, "$filestem.refnr") or die "Cannot read refnr file";
    open(SYMNR, "$filestem.symnr") or die "Cannot read symnr file";

    while($_=<REFNR>) { chop; push(@gnrref, $_); };
    while($_=<SYMNR>) { chop; $gsymnr{$_} = $gsymoffset + $i++; };

    $gtargetsnr = scalar @gnrref;

    $gwantednr = ($glimittargets > 0) ? $glimittargets : $gtargetsnr;

    if($gsnowserver == 2)
    {

	my $snowpid = StartSnow($iter, $gwantednr);


# old stuff 0 never made it work properly:
	# my $snowcommand = "nohup ". $gpathtosnow." -server " . $snowport
	#     . " -o allboth -F " . $filestem . ".net -A " 
	# 	. $filestem . ".arch > /dev/null 2>&1 &";

	# system($snowcommand);
	print "Snow started, may take a while to load\n";
    }
    else
    {
	print "Connecting to Snow\n";
    }
}


sub ReceiveFrom #($socket)
{
  my($socket) = $_[0];
  my($length, $char, $msg, $message, $received);

  $received = 0;
  $message = "";
  while ($received < 4)
  {
    recv $socket, $msg, 4 - $received, 0;
    $received += length $msg;
    $message .= $msg;
  }
  $length = unpack("N", $message);

  $received = 0;
  $message = "";
  while ($received < $length)
  {
    recv $socket, $msg, $length - $received, 0;
    $received += length $msg;
    $message .= $msg;
  }

  return $message;
}


sub AskSnowPipe
{
    my ($msg) = @_;
    my @res = ();
    my @lines =();

    print 'SNOWIN: ' . $msg if(LOGFLAGS & LOGSNIO);

    print SNOWWRITER ($msg);

    while (<SNOWREADER>)
    {
	push(@lines, $_);
	if(/\b([0-9]+):/) { push (@res, $1); };
	if($_ eq "\n") {$_ = <SNOWREADER>; last;} ## two newlines

    }

    print 'SNOWOUT: ' . join("", @lines), "\n" if(LOGFLAGS & LOGSNIO);

    return \@res;
}


sub AskSnowSlow
{
    my ($msg) = @_;
    my $parameters = "-o allboth";
    my @res;
    
    # First, establish a connection with the server.
    my $socket = IO::Socket::INET->new( Proto     => "tcp",
					PeerAddr  => "localhost",
					PeerPort  => $snowport,
				      );
    die "The server is down, sorry" unless ($socket);

    # Next, send the server your parameters.  Y
    # ou can (and should) use the command
    # commented below if you have no parameters to send:
    #send $socket, pack("N", 0), 0;
    send $socket, pack("N", length $parameters), 0;
    print $socket $parameters;

    # Whether you sent parameters or not, 
    # the server will then send you information
    # about the algorithms used in training the network.
    my $message = ReceiveFrom($socket);
    print "Snow: ", $message if(LOGGING);

    # Now, we're ready to start sending examples and receiving the results.
    # Send one example:
    send $socket, pack("N", length $msg), 0;
    print $socket $msg;

    # Receive the server's classification information:
    $message = ReceiveFrom($socket);

    # Last, tell the server that this client is done.
    send $socket, pack("N", 0), 0;
    
    print $message if(LOGGING);
    while($message=~/\b([0-9]+):/g) { push (@res, $1); };
    return \@res;
}

sub AskSnowDummy {}

sub AskSnow
{
    my ($msg, $socket) = @_;
    my @res = ();

    # Now, we're ready to start sending examples and receiving the results.
    # Send one example:
    send $socket, pack("N", length $msg), 0;
    print $socket $msg;
    print 'SNOWIN: ' . $msg if(LOGFLAGS & LOGSNIO);
    # Receive the server's classification information:
    my $message = ReceiveFrom($socket);
    print 'SNOWOUT: ' . $message if(LOGFLAGS & LOGSNIO);
    while($message=~/\b([0-9]+):/g) { push (@res, $1); };
    return \@res;
}



# sub LoadSpecs($filestem,
#
# Following command will create all initial unpruned problem specifications,
# in format spec(name,references), e.g.:
# spec(t119_zfmisc_1,[reflexivity_r1_tarski,t118_zfmisc_1,rc1_xboole_0,dt_k2_zfmisc_1,t1_xboole_1,rc2_xboole_0]).
# and print the into file foo.specs
# for i in `ls */*`; do perl -e   'while(<>) { if(m/^ *fof\( *([^, ]+) *,(.*)/) { ($nm,$rest)=($1,$2); if($rest=~m/^ *conjecture/) {$conjecture=$nm;} else {$h{$nm}=();}}} print "spec($conjecture,[" . join(",", keys %h) . "]).\n";' $i; done >foo.specs

# loads the specs
# sub LoadSpecs
# {
# #    LoadTables();
#     %gspec = ();
#     %gresults = ();
#     %gsubrefs = ();
#     %gsuperrefs = ();
#     open(SPECS, "$filestem.specs") or die "Cannot read specs file";
#     while (<SPECS>) {
# 	my ($ref,$refs,$ref1);

# 	m/^spec\( *([a-z0-9A-Z_]+) *, *\[(.*)\] *\)\./ 
# 	    or die "Bad spec info: $_";

# 	($ref, $refs) = ($1, $2);
# 	my @refs = split(/\,/, $refs);
# 	$gspec{$ref} = {};
# 	$gresults{$ref} = [];
# 	my $new_spec = [szs_INIT, $#refs, -1, [@refs], []];
# 	push(@{$gresults{$ref}}, $new_spec);
# 	# also some sanity checking
# 	foreach $ref1 (@refs)
# 	{
# 	    exists $grefnr{$ref} or die "Unknown reference $ref in $_";
# 	    ${$gspec{$ref}}{$ref1} = ();
# 	}
#     }
#     close SPECS;
# }



StartServer($giterrecover);


my $server = IO::Socket::INET->new( Proto     => "tcp",
				 LocalPort => $gport,
				 Listen    => SOMAXCONN,
				 Reuse     => 1);

die "cannot setup server" unless $server;
print "[Server $0 accepting clients]\n";

my %snowprev = ();

while ($client = $server->accept())
{
    $client->autoflush(1);

    print "[accepted client]\n";
#    $msg  = ReceiveFrom($client);
#    while( $_=<$client> ) { $msg = $msg . $_; }
    my $msgnr = 0;
    my $limit = 64;
    my $snowparameters = " -o allpredictions -L $limit ";
    my $snowsocket;
    
    if($gsnowserver == 1)
    {
	$snowsocket = IO::Socket::INET->new( Proto     => "tcp",
					PeerAddr  => "localhost",
					PeerPort  => $snowport,
				      );
	die "The SNoW server is down, sorry" unless ($snowsocket);
    
	# Next, send the server your parameters.  Y
	# ou can (and should) use the command
	# commented below if you have no parameters to send:
	#send $socket, pack("N", 0), 0;
	send $snowsocket, pack("N", length $snowparameters), 0;
	print $snowsocket $snowparameters;
	
	# Whether you sent parameters or not, 
	# the server will then send you information
	# about the algorithms used in training the network.
	my $snowmessage = ReceiveFrom($snowsocket);
	print 'Snow: ', $snowmessage if(LOGFLAGS & LOGSNIO);
    }


    while(my $msg = <$client>)
{    
    print 'ADVIN: ', $msg if(LOGFLAGS & LOGADVIO);
    chop $msg;
    $msg =~ m/ *\[ *(.*) *\] */;
    $msg = $1;
    print "[received bytes]\n";
#    @res  = unpack("a", $msg);
    my @res = split(/ *, */, $msg);
    $msgnr++;
    if($msgnr == 1) { # SetupProblemParams(\@res); 
    }
    else
    {
	my @res1   = map { if(exists($gsymnr{$_})) {$gsymnr{$_} } else {'@@@' . $_ . '@@@'} } @res;
#    $msgout = pack("a", @res2);
	my $msgout = join(",", @res1);
	my $msg1;
	if(exists $snowprev{$msg}) { $msg1=  $snowprev{$msg}; }
	else
	{
	    if($gsnowserver == 1)
	    {
		$msg1 = AskSnow($msgout . ':', $snowsocket);
	    }
	    elsif($gsnowserver == 2)
	    {
		$msg1 = AskSnowPipe($msgout . ':' . "\n");
	    }
	    print @$msg1, "\n" if(LOGGING);
	    $snowprev{$msg} = $msg1;
	}
	my @msg2 = map { $gnrref[$_] } @$msg1;
	my $outnr = min($limit, 1 + $#msg2);
	my @msg3  = @msg2[0 .. ($outnr -1)];
	my $msgout1 = join(",", @msg3);
	print 'ADVOUT: ', $msgout1, "\n" if(LOGFLAGS & LOGADVIO);
#    send $client, pack("N", length $msgout), 0;
#	print $client '[' . '].' . "\n";
    print $client '[' . $msgout1 . '].' . "\n";
    }
}
    # Last, tell the SNoW server that this client is done.
if($gsnowserver == 1)
{
    send $snowsocket, pack("N", 0), 0;
}
#    close $client;
    print "[closed client]\n";
}





package CPAN::Testers::WWW::Statistics;

use 5.006; #due to 'warnings' pragma
use warnings;
use strict;
use vars qw($VERSION);

$VERSION = '0.95';

#----------------------------------------------------------------------------

=head1 NAME

CPAN::Testers::WWW::Statistics - CPAN Testers Statistics website.

=head1 DESCRIPTION

CPAN Testers Statistics comprises the actual website pages, a CGI tool to find
testers, and some backend code to help map tester address to a real identity.

=cut

# -------------------------------------
# Library Modules

use base qw(Class::Accessor::Fast);

use Config::IniFiles;
use CPAN::Testers::Common::DBUtils;
use File::Basename;
use File::Path;
use IO::File;
use Regexp::Assemble;

use CPAN::Testers::WWW::Statistics::Pages;
use CPAN::Testers::WWW::Statistics::Graphs;

# -------------------------------------
# Public Methods

=head1 INTERFACE

=head2 The Constructor

=over 4

=item * new

Statistics creation object. Provides all the configuration and logging
functionality, as well the interface to the lower level functionality for Page
and Graph creation.

new() takes an option hash as an argument, which may contain the following
keys.

  config    => path to configuration file [required]

  directory => path to output directory
  mainstore => path to main data storage file
  leadstore => path to leaderboard data storage file
  templates => path to templates directory
  database  => path to SQLite database file
  address   => path to address file
  mailrc    => path to 01mailrc.txt file
  builder   => path to output file from builder log parser

  logfile   => path to logfile
  logclean  => will overwrite any existing logfile if set

Note that while 'directory', 'templates', 'database' and 'address' are optional
as parameters, if they are not provided as parameters, then they MUST be
specified within the 'MASTER' section of the configuration file.

=back

=cut

sub _alarm_handler () { return; }

sub new {
    my $class = shift;
    my %hash  = @_;

    my $self = {};
    bless $self, $class;

    # ensure we have a configuration file
    die "Must specify the configuration file\n"             unless(   $hash{config});
    die "Configuration file [$hash{config}] not found\n"    unless(-f $hash{config});

    # load configuration file
    my $cfg;
    local $SIG{'__WARN__'} = \&_alarm_handler;
    eval { $cfg = Config::IniFiles->new( -file => $hash{config} ); };
    die "Cannot load configuration file [$hash{config}]\n"  unless($cfg && !$@);
    $self->{cfg} = $cfg;

    # configure databases
    for my $db (qw(CPANSTATS)) {
        die "No configuration for $db database\n"   unless($cfg->SectionExists($db));
        my %opts = map {my $v = $cfg->val($db,$_); defined($v) ? ($_ => $v) : () }
                        qw(driver database dbfile dbhost dbport dbuser dbpass);
        $self->{$db} = CPAN::Testers::Common::DBUtils->new(%opts);
        die "Cannot configure $db database\n" unless($self->{$db});
    }

    my %OSNAMES;
    my @rows = $self->{CPANSTATS}->get_query('array',q{SELECT osname,ostitle FROM osname ORDER BY id});
    for my $row (@rows) {
        $OSNAMES{lc $row->[0]} ||= $row->[1];
    }
    $self->osnames( \%OSNAMES );

    my $ra = Regexp::Assemble->new();
    my @NOREPORTS = split("\n", $cfg->val('NOREPORTS','list'));
    for(@NOREPORTS) {
        s/\s+\#.*$//;   #remove comments
        $ra->add($_);
    }
    $self->noreports($ra->re);

    my @TOCOPY = split("\n", $cfg->val('TOCOPY','LIST'));
    $self->tocopy(\@TOCOPY);

    my %TOLINK;
    for my $link ($cfg->Parameters('TOLINK')) {
        my $file = $cfg->val('TOLINK',$link);
        $TOLINK{$link} = $file;
    }
    $self->tolink(\%TOLINK);

    $self->mainstore( _defined_or( $hash{mainstore},  $cfg->val('MASTER','mainstore' ) ));
    $self->leadstore( _defined_or( $hash{leadstore},  $cfg->val('MASTER','leadstore' ) ));
    $self->monthstore(_defined_or( $hash{monthstore}, $cfg->val('MASTER','monthstore'), 'cpanstats-%s.json' ));
    $self->templates( _defined_or( $hash{templates},  $cfg->val('MASTER','templates' ) ));
    $self->database(  _defined_or( $hash{database},   $cfg->val('MASTER','database'  ) ));
    $self->address(   _defined_or( $hash{address},    $cfg->val('MASTER','address'   ) ));
    $self->missing(   _defined_or( $hash{missing},    $cfg->val('MASTER','missing'   ) ));
    $self->mailrc(    _defined_or( $hash{mailrc},     $cfg->val('MASTER','mailrc'    ) ));
    $self->logfile(   _defined_or( $hash{logfile},    $cfg->val('MASTER','logfile'   ) ));
    $self->logclean(  _defined_or( $hash{logclean},   $cfg->val('MASTER','logclean'  ), 0 ));
    $self->directory( _defined_or( $hash{directory},  $cfg->val('MASTER','directory' ) ));
    $self->copyright(                                 $cfg->val('MASTER','copyright' ) );
    $self->builder(   _defined_or( $hash{builder},    $cfg->val('MASTER','builder'   ) ));

    $self->_log("mainstore =".($self->mainstore  || ''));
    $self->_log("leadstore =".($self->leadstore  || ''));
    $self->_log("monthstore=".($self->monthstore || ''));
    $self->_log("templates =".($self->templates  || ''));
    $self->_log("database  =".($self->database   || ''));
    $self->_log("address   =".($self->address    || ''));
    $self->_log("missing   =".($self->missing    || ''));
    $self->_log("mailrc    =".($self->mailrc     || ''));
    $self->_log("logfile   =".($self->logfile    || ''));
    $self->_log("logclean  =".($self->logclean   || ''));
    $self->_log("directory =".($self->directory  || ''));
    $self->_log("builder   =".($self->builder    || ''));

    die "Must specify the output directory\n"           unless($self->directory);
    die "Must specify the template directory\n"         unless($self->templates);
    die "Must specify a valid mailrc path\n"            unless($self->mailrc && -f $self->mailrc);

    return $self;
}

=head2 Public Methods

=over 4

=item * make_pages

Method to manage the data update and creation of all the statistics web pages.

Note that this method incorporate all of the method functionality of update, 
make_basics, make_matrix and make_stats.

=item * update

Method to manage the data update only.

=item * make_basics

Method to manage the creation of the basic statistics web pages.

=item * make_matrix

Method to manage the creation of the matrix style statistics web pages.

=item * make_stats

Method to manage the creation of the tabular style statistics web pages.

=item * make_leaders

Method to manage the creation of the OS leaderboard web pages.

=item * make_graphs

Method to manage the creation of all the statistics graphs.

=item * ranges

Returns the specific date range array reference, as held in the configuration
file.

=item * osname

Returns the print form of a recorded OS name.

=back

=cut

__PACKAGE__->mk_accessors(
    qw( directory mainstore leadstore monthstore templates database address 
        builder missing mailrc logfile logclean copyright noreports tocopy 
        tolink osnames));

sub make_pages {
    my $self = shift;
    $self->_check_files();

    my $stats = CPAN::Testers::WWW::Statistics::Pages->new(parent => $self);
    $stats->update_full();
}

sub update {
    my $self = shift;
    $self->_check_files();

    my $stats = CPAN::Testers::WWW::Statistics::Pages->new(parent => $self);
    $stats->update_data();
}

sub make_basics {
    my $self = shift;
    $self->_check_files();

    my $stats = CPAN::Testers::WWW::Statistics::Pages->new(parent => $self);
    $stats->build_basics();
}

sub make_matrix {
    my $self = shift;
    $self->_check_files();

    my $stats = CPAN::Testers::WWW::Statistics::Pages->new(parent => $self);
    $stats->build_matrices();
}

sub make_stats {
    my $self = shift;
    $self->_check_files();

    my $stats = CPAN::Testers::WWW::Statistics::Pages->new(parent => $self);
    $stats->build_stats();
}

sub make_leaders {
    my $self = shift;
    $self->_check_files();

    my $stats = CPAN::Testers::WWW::Statistics::Pages->new(parent => $self);
    $stats->build_leaders();
}

sub make_graphs {
    my $self = shift;
    my $stats = CPAN::Testers::WWW::Statistics::Graphs->new(parent => $self);
    $stats->create();
}

sub ranges {
    my ($self,$section) = @_;
    return  unless($section);
    my @now = localtime(time);
    if($now[4]==0) { $now[5]--; $now[4]=11; }
    my $now = sprintf "%04d%02d", $now[5]+1900, $now[4]+1;

    my @RANGES;
    if($section eq 'NONE') {
        @RANGES = ('00000000-99999999');
    } else {
        my @ranges = split("\n", $self->{cfg}->val($section,'LIST'));
        for my $range (@ranges) {
            my ($fdate,$tdate) = split('-',$range,2);
            next            if($fdate > $now);
            $tdate = $now   if($tdate > $now);
            push @RANGES, "$fdate-$tdate";
        }
    }
        
    return \@RANGES;
}

sub osname {
    my ($self,$name) = @_;
    my $osnames = $self->osnames();
    return $osnames->{lc $name} || $name;
}

# -------------------------------------
# Private Methods

sub _check_files {
    my $self = shift;
    die "Template directory not found\n"                unless(-d $self->templates);
    die "Must specify the path of the SQL database\n"   unless(   $self->database);
    die "Archive SQLite database not found\n"           unless(-f $self->database);
    die "Must specify the path of the address file\n"   unless(   $self->address);
    die "Address file not found\n"                      unless(-f $self->address);
}

sub _log {
    my $self = shift;
    my $log = $self->logfile or return;
    mkpath(dirname($log))   unless(-f $log);

    my $mode = $self->logclean ? 'w+' : 'a+';
    $self->logclean(0);

    my @dt = localtime(time);
    my $dt = sprintf "%04d/%02d/%02d %02d:%02d:%02d", $dt[5]+1900,$dt[4]+1,$dt[3],$dt[2],$dt[1],$dt[0];

    my $fh = IO::File->new($log,$mode) or die "Cannot write to log file [$log]: $!\n";
    print $fh "$dt ", @_, "\n";
    $fh->close;
}

sub _defined_or {
    while(@_) {
        my $value = shift;
        return $value   if(defined $value);
    }

    return;
}

q("I am NOT a number!");

__END__

=head1 BUGS, PATCHES & FIXES

There are no known bugs at the time of this release. However, if you spot a
bug or are experiencing difficulties, that is not explained within the POD
documentation, please send bug reports and patches to the RT Queue (see below).

Fixes are dependant upon their severity and my availablity. Should a fix not
be forthcoming, please feel free to (politely) remind me.

RT Queue -
http://rt.cpan.org/Public/Dist/Display.html?Name=CPAN-Testers-WWW-Statistics

=head1 SEE ALSO

L<CPAN::Testers::Data::Generator>,
L<CPAN::Testers::WWW::Reports>

F<http://www.cpantesters.org/>,
F<http://stats.cpantesters.org/>,
F<http://wiki.cpantesters.org/>

=head1 AUTHOR

  Barbie, <barbie@cpan.org>
  for Miss Barbell Productions <http://www.missbarbell.co.uk>.

=head1 COPYRIGHT AND LICENSE

  Copyright (C) 2005-2011 Barbie for Miss Barbell Productions.

  This module is free software; you can redistribute it and/or
  modify it under the same terms as Perl itself.

=cut

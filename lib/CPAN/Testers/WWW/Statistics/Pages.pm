package CPAN::Testers::WWW::Statistics::Pages;

use warnings;
use strict;
use vars qw($VERSION);

$VERSION = '0.95';

#----------------------------------------------------------------------------

=head1 NAME

CPAN::Testers::WWW::Statistics::Pages - CPAN Testers Statistics pages.

=head1 SYNOPSIS

  my %hash = { config => 'options' };
  my $obj = CPAN::Testers::WWW::Statistics->new(%hash);
  my $ct = CPAN::Testers::WWW::Statistics::Pages->new(parent => $obj);

  $ct->update_full();       # updates statistics data and web pages

  # alternatively called individual processes

  $ct->update_data();       # updates statistics data
  $ct->build_basics();      # updates basic web pages
  $ct->build_matrices();    # updates matrix style web pages
  $ct->build_stats();       # updates stats style web pages

=head1 DESCRIPTION

Using the cpanstats database, this module extracts all the data and generates
all the HTML pages needed for the CPAN Testers Statistics website. In addition,
also generates the data files in order generate the graphs that appear on the
site.

Note that this package should not be called directly, but via its parent as:

  my %hash = { config => 'options' };
  my $obj = CPAN::Testers::WWW::Statistics->new(%hash);

  $obj->make_pages();       # updates statistics data and web pages

  # alternatively called individual processes

  $obj->update();           # updates statistics data
  $obj->make_basics();      # updates basic web pages
  $obj->make_matrix();      # updates matrix style web pages
  $obj->make_stats();       # updates stats style web pages

=cut

# -------------------------------------
# Library Modules

use Data::Dumper;
use File::Basename;
use File::Copy;
use File::Path;
use File::Slurp;
use HTML::Entities;
use IO::File;
use JSON;
use Sort::Versions;
use Template;
#use Time::HiRes qw ( time );
use Time::Piece;

# -------------------------------------
# Variables

my ($known_s,$known_t) = (0,0);

my %month = (
    0 => 'January',   1 => 'February', 2 => 'March',     3 => 'April',
    4 => 'May',       5 => 'June',     6 => 'July',      7 => 'August',
    8 => 'September', 9 => 'October', 10 => 'November', 11 => 'December'
);

my $ADAY = 86400;

my %matrix_limits = (
    all     => [ 1000, 5000 ],
    month   => [  100,  500 ]
);

# -------------------------------------
# Subroutines

=head1 INTERFACE

=head2 The Constructor

=over 4

=item * new

Page creation object. Allows the user to turn or off the progress tracking.

new() takes an option hash as an argument, which may contain 'progress => 1'
to turn on the progress tracker and/or 'database => $db' to indicate the path
to the database. If no database path is supplied, './cpanstats.db' is used.

=back

=cut

sub new {
    my $class = shift;
    my %hash  = @_;

    die "Must specify the parent statistics object\n"   unless(defined $hash{parent});

    my $self = {parent => $hash{parent}};
    bless $self, $class;

    $self->setdates();
    return $self;
}

=head2 Public Methods

=over 4

=item * setdates

Prime all key date variable.

=item * update_full

Full update of data and pages.

=item * update_data

Update data and store in JSON format.

=item * build_basics

Create the basic set of pages,those require no statistical calculation.

=item * build_matrices

Create the matrices pages and distribution list pages.

=item * build_stats

Create all other statistical pages; monthly tables, interesting stats, etc.

=item * build_leaders

Create all OS Leaderboards.

=back

=cut

sub setdates {
    my $self = shift;
    $self->{parent}->_log("init");

    my $t = localtime;
    my @datetime = localtime;
    my $THISYEAR = ($datetime[5] +1900);
    $self->{dates}{RUNDATE}
        = sprintf "%d%s %s %d",
            $datetime[3], _ext($datetime[3]), $month{$datetime[4]}, $THISYEAR;
    $self->{dates}{RUNTIME} = $t->strftime();

    # LIMIT is the last date for all data
    $self->{dates}{LIMIT}    = ($THISYEAR) * 100 + $datetime[4] + 1;
    if($datetime[4] == 0) {
        $datetime[4] = 11;
        $THISYEAR--;
    }

    # STATDATE/THISDATE is the Month/Year stats are run for
    $self->{dates}{STATDATE} = sprintf "%s %d", $month{int($datetime[4])}, $THISYEAR;
    $self->{dates}{THISDATE} = sprintf "%04d%02d", $THISYEAR, int($datetime[4]);

    # LASTDATE/THATDATE is the previous Month/Year for a full matrix
    $datetime[4]--;
    my $THATYEAR = $THISYEAR;
    if($datetime[4] == 0) {
        $datetime[4] = 11;
        $THATYEAR--;
    }
    $self->{dates}{LASTDATE}  = sprintf "%04d%02d", $THATYEAR, int($datetime[4]);
    $self->{dates}{THATDATE}  = sprintf "%s %d", $month{int($datetime[4])}, $THATYEAR;
    $self->{dates}{SHORTDATE} = sprintf "%02d/%02d", int($datetime[4])+1, $THATYEAR - 2000;

    #print STDERR "THISYEAR=[$THISYEAR]\n";
    #print STDERR "LIMIT=[$self->{dates}{LIMIT}]\n";
    #print STDERR "STATDATE=[$self->{dates}{STATDATE}]\n";
    #print STDERR "RUNDATE=[$self->{dates}{RUNDATE}]\n";
}

sub update_full {
    my $self = shift;

    $self->{parent}->_log("start update_full");
    $self->build_basics();
    $self->build_data();
    $self->build_matrices();
    $self->build_stats();
    $self->build_leaders();
    $self->{parent}->_log("finish update_full");
}

sub update_data {
    my $self = shift;

    $self->{parent}->_log("start update_data");
    $self->build_data();
    $self->{parent}->_log("finish update_data");
}

sub build_basics {
    my $self = shift;

    $self->{parent}->_log("start build_basics");

    ## BUILD INFREQUENT PAGES
    $self->_write_basics();
    $self->_missing_in_action();

    $self->{parent}->_log("finish build_basics");
}

sub build_matrices {
    my $self = shift;

    $self->{parent}->_log("start build_matrices");
    my $storage = $self->{parent}->mainstore();
    if($storage && -f $storage) {
        $self->{parent}->_log("building dist hash from storage");
        $self->storage_read($storage);

        my @versions = sort {versioncmp($b,$a)} keys %{$self->{perls}};
        $self->{versions} = \@versions;

        $self->_build_osname_matrix();
        $self->_build_platform_matrix();
    }
    $self->{parent}->_log("finish build_matrices");
}

sub build_stats {
    my $self = shift;

    ## BUILD INDEPENDENT STATS
    $self->_report_cpan();
    $self->_no_reports();

    ## BUILD MONTHLY STATS
    $self->_build_monthly_stats();

    $self->{parent}->_log("stats start");
    my $storage = $self->{parent}->mainstore();
    if($storage && -f $storage) {
        $self->{parent}->_log("building dist hash from storage");
        my ($testers) = $self->storage_read($storage);

        for my $tester (keys %$testers) {
            $self->{counts}{$testers->{$tester}{first}}{first}++;
            $self->{counts}{$testers->{$tester}{last}}{last}++;
        }

        $testers = {};  # save memory

        my @versions = sort {versioncmp($b,$a)} keys %{$self->{perls}};
        $self->{versions} = \@versions;

        ## BUILD STATS PAGES
        $self->_report_interesting();
        $self->_build_monthly_stats_files();
        $self->_build_failure_rates();
        $self->_build_performance_stats();

        ## BUILD INDEX PAGE
        $self->_write_index();
    }
    $self->{parent}->_log("stats finish");
}

sub build_leaders {
    my $self = shift;

    $self->{parent}->_log("leaders start");

    ## BUILD OS LEADERBOARDS
    $self->_build_osname_leaderboards();

    $self->{parent}->_log("leaders finish");
}

=head2 Private Methods

=head3 Data Methods

=over 4

=item * build_data

=item * storage_read

=item * storage_write

=back

=cut

sub build_data {
    my $self = shift;

    $self->{parent}->_log("building rate hash");

    my ($d1,$d2) = (time(), time() - $ADAY);
    my @date = localtime($d2);
    my $date = sprintf "%04d%02d%02d", $date[5]+1900, $date[4]+1, $date[3];
    my @tday = localtime($d1);
    my $tday = sprintf "%04d%02d%02d", $tday[5]+1900, $tday[4]+1, $tday[3];

    my $testers = {};
    my $lastid = 0;
    my $storage = $self->{parent}->mainstore();
    if($storage && -f $storage) {
        $self->{parent}->_log("building dist hash from storage");
        ($testers,$lastid) = $self->storage_read($storage);

        # only remember the latest release for 'dists' hash
        my $iterator = $self->{parent}->{CPANSTATS}->iterator('hash',"SELECT dist,version FROM ixlatest");
        while(my $row = $iterator->()) {
            next    if($self->{dists}{$row->{dist}} && $self->{dists}{$row->{dist}}->{VER} eq $row->{version});
            $self->{dists}{$row->{dist}} = { ALL => 0, IXL => 0, VER => $row->{version}};
        }

    } else {
        $self->{parent}->_log("building dist hash from scratch");

        my $iterator = $self->{parent}->{CPANSTATS}->iterator('hash',"SELECT dist,version FROM ixlatest");
        while(my $row = $iterator->()) {
            $self->{dists}{$row->{dist}}->{ALL} = 0;
            $self->{dists}{$row->{dist}}->{IXL} = 0;
            $self->{dists}{$row->{dist}}->{VER} = $row->{version};
        }

        $self->{parent}->_log("building stats hash");

        $self->{count}{$_} ||= 0    for(qw(posters entries reports distros));
        $self->{xrefs} = { posters => {}, entries => {}, reports => {} },
        $self->{xlast} = { posters => [], entries => [], reports => [] },
    }

#use Data::Dumper;
#$self->{parent}->_log("build:1.".Dumper($self->{build}));

    # reports builder performance stats
    for my $d (keys %{$self->{build}}) {
        $self->{build}{$d}->{old} = 0;
    }
    my $file = $self->{parent}->builder();
    if($file && -f $file) {
        if(my $fh = IO::File->new($file,'r')) {
            while(<$fh>) {
                my ($d,$r,$p) = /(\d+),(\d+),(\d+)/;
                next    unless($d);
                $self->{build}{$d}->{webtotal}  = $r;
                $self->{build}{$d}->{webunique} = $p;
                $self->{build}{$d}->{old} = 1;
            }
            $fh->close;
        }
    }
    $self->{build}{$date}->{old} = 1;	# keep the tally for yesterday
    $self->{build}{$tday}->{old} = 2;	# keep the tally for today, but don't use
    for my $d (keys %{$self->{build}}) {
        delete $self->{build}{$d} unless($self->{build}{$d}->{old});
    }
#$self->{parent}->_log("build:2.".Dumper($self->{build}));

    # 0,  1,    2,     3,        4,      5     6,       7,        8,    9,      10      11        12
    # id, guid, state, postdate, tester, dist, version, platform, perl, osname, osvers, fulldate, type

    $self->{parent}->_log("building dist hash from $lastid");
    my $iterator = $self->{parent}->{CPANSTATS}->iterator('array',"SELECT * FROM cpanstats WHERE type = 2 AND id > $lastid ORDER BY id LIMIT 1000000");
    while(my $row = $iterator->()) {
        $row->[8] =~ s/\s.*//;  # only need to know the main release
        $lastid = $row->[0];

        {
            my $osname = $self->{parent}->osname($row->[9]);
            my $name   = $self->_tester_name($row->[4]);

            $self->{stats}{$row->[3]}{reports}++;
            $self->{stats}{$row->[3]}{state   }{$row->[2]}++;
            #$self->{stats}{$row->[3]}{dist    }{$row->[5]}++;
            #$self->{stats}{$row->[3]}{version }{$row->[6]}++;

            # check distribution tallies
            if(defined $self->{dists}{$row->[5]}) {
                $self->{dists}{$row->[5]}{ALL}++;

                if($self->{dists}{$row->[5]}->{VER} eq $row->[6]) {
                    $self->{dists}{$row->[5]}{IXL}++;

                    # check failure rates
                    $self->{fails}{$row->[5]}{$row->[6]}{fail}++    if($row->[2] eq 'fail');
                    $self->{fails}{$row->[5]}{$row->[6]}{pass}++    if($row->[2] eq 'pass');
                    $self->{fails}{$row->[5]}{$row->[6]}{total}++;
                }
            }

            # build matrix stats
            my $perl = $row->[8];
            $perl =~ s/\s.*//;  # only need to know the main release
            $self->{perls}{$perl} = 1;

            $self->{pass}    {$row->[7]}{$perl}{all}{$row->[5]} = 1;
            $self->{platform}{$row->[7]}{$perl}{all}++;
            $self->{osys}    {$osname}  {$perl}{all}{$row->[5]} = 1;
            $self->{osname}  {$osname}  {$perl}{all}++;

            if($row->[3] == $self->{dates}{LASTDATE}) {
                $self->{pass}    {$row->[7]}{$perl}{month}{$row->[5]} = 1;
                $self->{platform}{$row->[7]}{$perl}{month}++;
                $self->{osys}    {$osname}  {$perl}{month}{$row->[5]} = 1;
                $self->{osname}  {$osname}  {$perl}{month}++;
            }

            # record tester activity
            $testers->{$name}{first} ||= $row->[3];
            $testers->{$name}{last}    = $row->[3];
            $self->{counts}{$row->[3]}{testers}{$name} = 1;

            my $day = substr($row->[11],0,8);
            $self->{build}{$day}{reports}++ if(defined $self->{build}{$day});
        }

        my @row = (0, @$row);

        $self->{count}{posters} = $row[1];
        $self->{count}{entries}++;
        $self->{count}{reports}++;

        my $type = 'reports';
$self->{parent}->_log("checkpoint: count=$self->{count}{$type}, lastid=$lastid") if($self->{count}{$type} % 10000 == 0);

        if($storage && $self->{count}->{$type} % 100000 == 0) {
            # due to the large data structures used, long runs (eg starting from
            # scratch) should save the current state periodically.
            $self->storage_write($storage,$testers,$lastid)
        }

        if($self->{count}{$type} == 1 || ($self->{count}->{$type} % 500000) == 0) {
            $self->{xrefs}{$type}->{$self->{count}->{$type}} = \@row;
        } else {
            $self->{xlast}{$type} = \@row;
        }
    }
#use Data::Dumper;
#$self->{parent}->_log("build:3.".Dumper($self->{build}));
#$self->{parent}->_log("build:4.".Dumper($testers));

    $self->storage_write($storage,$testers,$lastid) if($storage);

    for my $tester (keys %$testers) {
        $self->{counts}{$testers->{$tester}{first}}{first}++;
        $self->{counts}{$testers->{$tester}{last}}{last}++;
    }
#$self->{parent}->_log("build:5.".Dumper($self->{counts}));

    my @versions = sort {versioncmp($b,$a)} keys %{$self->{perls}};
    $self->{versions} = \@versions;

    $self->{parent}->_log("stats hash built");
}

sub storage_read {
    my ($self,$storage) = @_;
    my $data = read_file($storage);
    my $store = decode_json($data);
    $self->{$_} = $store->{$_}  for(qw(stats dists fails perls pass platform osys osname build counts count xrefs xlast));
    return($store->{testers},$store->{lastid});
}

sub storage_write {
    my ($self,$storage,$testers,$lastid) = @_;
    my $store = {};

    $store->{$_} = $self->{$_}  for(qw(stats dists fails perls pass platform osys osname build counts count xrefs xlast));
    $store->{testers} = $testers;
    $store->{lastid} = $lastid;

    my $data = encode_json($store);
#$self->{parent}->_log("storage: data=".Dumper($data));
    overwrite_file($storage,$data);
}

=head3 Page Creation Methods

=over 4

=item * _write_basics

Write out basic pages, all of which are simply built from the templates,
without any data processing required.

=cut

sub _write_basics {
    my $self = shift;
    my $directory = $self->{parent}->directory;
    my $templates = $self->{parent}->templates;
    my $database  = $self->{parent}->database;
    my $results   = "$directory/stats";
    mkpath($results);

    $self->{parent}->_log("writing basic files");

    my $ranges1 = $self->{parent}->ranges('TEST_RANGES');
    my $ranges2 = $self->{parent}->ranges('CPAN_RANGES');

    # additional pages not requiring metrics
    my %pages = (
        cpanmail => {},
        response => {},
        perform  => {},
        terms    => {},
        graphs   => {},
        graphs1  => {RANGES => $ranges1, template=>'archive', PREFIX=>'stats1' ,TITLE=>'Monthly Report Counts'},
        graphs2  => {RANGES => $ranges1, template=>'archive', PREFIX=>'stats2' ,TITLE=>'Testers, Platforms and Perls'},
        graphs3  => {RANGES => $ranges1, template=>'archive', PREFIX=>'stats3' ,TITLE=>'Monthly Non-Passing Reports Counts'},
        graphs4  => {RANGES => $ranges1, template=>'archive', PREFIX=>'stats4' ,TITLE=>'Monthly Tester Fluctuations'},
        graphs5  => {RANGES => $ranges1, template=>'archive', PREFIX=>'pcent1' ,TITLE=>'Monthly Report Percentages'},
        graphs6  => {RANGES => $ranges2, template=>'archive', PREFIX=>'stats6' ,TITLE=>'All Distribution Uploads per Month'},
        graphs12 => {RANGES => $ranges2, template=>'archive', PREFIX=>'stats12',TITLE=>'New Distribution Uploads per Month'}
    );

    $self->{parent}->_log("building support pages");
    $self->_writepage($_,$pages{$_})    for(keys %pages);

    # copy files
    $self->{parent}->_log("copying static files");
    my $tocopy = $self->{parent}->tocopy;
    for my $filename (@$tocopy) {
        my $source = $templates . "/$filename";
        if(-f $source) {
            my $target = $directory . "/$filename";
            next    if(-f $target);

            mkpath( dirname($target) );
            if(-d dirname($target)) {
                copy( $source, $target );
            } else {
                warn "Missing directory: $target\n";
            }
        } else {
            warn "Missing file: $source\n";
        }
    }

    #link files
    $self->{parent}->_log("linking static files");
    my $tolink = $self->{parent}->tolink;
    for my $filename (keys %$tolink) {
        my $source = $directory . "/$filename";
        my $target = $directory . '/'.$tolink->{$filename};

        next    if(-f $target);
        if(-f $source) {
            link($target,$source);
        } else {
            warn "Missing file: $source\n";
        }
    }
}

=item * _write_index

Writes out the main index page, after all stats have been calculated.

=cut

sub _write_index {
    my $self = shift;
    my $directory = $self->{parent}->directory;
    my $templates = $self->{parent}->templates;
    my $database  = $self->{parent}->database;

    $self->{parent}->_log("writing index file");

    # calculate growth rates
    my ($d1,$d2) = (time(), time() - $ADAY);
    my @date = localtime($d2);
    my $date = sprintf "%04d%02d%02d", $date[5]+1900, $date[4]+1, $date[3];

    my @rows = $self->{parent}->{CPANSTATS}->get_query('array',"SELECT COUNT(*) FROM cpanstats WHERE type = 2 AND fulldate like '$date%'");
    $self->{rates}{report} = $rows[0]->[0] ? $ADAY / $rows[0]->[0] * 1000 : $ADAY / 10000 * 1000;
    @rows = $self->{parent}->{CPANSTATS}->get_query('array',"SELECT COUNT(*) FROM uploads WHERE released > $d2 and released < $d1");
    $self->{rates}{distro} = $rows[0]->[0] ? $ADAY / $rows[0]->[0] * 1000 : $ADAY / 60 * 1000;

    $self->{rates}{report} = 1000 if($self->{rates}{report} < 1000);
    $self->{rates}{distro} = 1000 if($self->{rates}{distro} < 1000);

    # calculate database metrics
    my $mtime = (stat($database))[9];
    my @ltime = localtime($mtime);
    $self->{DATABASE2} = sprintf "%d%s %s %d", $ltime[3],_ext($ltime[3]),$month{$ltime[4]},$ltime[5]+1900;
    my $DATABASE1 = sprintf "%04d/%02d/%02d", $ltime[5]+1900,$ltime[4]+1,$ltime[3];
    my $DBSZ_UNCOMPRESSED = int((-s $database        ) / (1024 * 1024));
    my $DBSZ_COMPRESSED   = int((-s $database . '.gz') / (1024 * 1024));

    # index page
    my %pages = (
        index    => {
            THISDATE            => $self->{dates}{THISDATE},
            DATABASE            => $DATABASE1,
            DBSZ_COMPRESSED     => $DBSZ_COMPRESSED,
            DBSZ_UNCOMPRESSED   => $DBSZ_UNCOMPRESSED,
            report_count        => $self->{count}{reports},
            distro_count        => $self->{count}{distros},
            report_rate         => $self->{rates}{report},
            distro_rate         => $self->{rates}{distro}
        },
    );

    $self->_writepage($_,$pages{$_})    for(keys %pages);
}

=item * _report_interesting

Generates the interesting stats page

=cut

sub _report_interesting {
    my $self  = shift;
    my %tvars;

    $self->{parent}->_log("building interesting page");

    my (@bydist,@byvers);
    my $inx = 20;
    for my $dist (sort {$self->{dists}{$b}{ALL} <=> $self->{dists}{$a}{ALL}} keys %{$self->{dists}}) {
        push @bydist, [$self->{dists}{$dist}{ALL},$dist];
        last    if(--$inx <= 0);
    }
    $inx = 20;
    for my $dist (sort {$self->{dists}{$b}{IXL} <=> $self->{dists}{$a}{IXL}} keys %{$self->{dists}}) {
        push @byvers, [$self->{dists}{$dist}{IXL},$dist,$self->{dists}{$dist}{VER}];
        last    if(--$inx <= 0);
    }

    $tvars{BYDIST} = \@bydist;
    $tvars{BYVERS} = \@byvers;

    my $type = 'reports';
    $self->{xrefs}{$type}{$self->{count}{$type}} = $self->{xlast}{$type};

    for my $key (sort {$b <=> $a} keys %{ $self->{xrefs}{$type} }) {
        my @row = @{ $self->{xrefs}{$type}{$key} };

        $row[0] = $key;
        $row[3] = uc $row[3];
        $row[5] = $self->_tester_name($row[5])  if($row[5] && $row[5] =~ /\@/);
        push @{ $tvars{ uc($type) } }, \@row;
    }

    my @headings = qw( count grade postdate tester dist version platform perl osname osvers fulldate );
    $tvars{HEADINGS} = \@headings;
    $self->_writepage('interest',\%tvars);
}

=item * _report_cpan

Generates the statistic pages that relate specifically to CPAN.

=cut

sub _report_cpan {
    my $self = shift;
    my (%authors,%distros,%tvars);

    $self->{parent}->_log("building cpan trends page");

    my $next = $self->{parent}->{CPANSTATS}->iterator('hash',"SELECT * FROM uploads ORDER BY released");
    while(my $row = $next->()) {
        next    if($row->{dist} eq 'perl');

        my $date = _parsedate($row->{released});
        $authors{$row->{author}}{count}++;
        $distros{$row->{dist}}{count}++;
        $authors{$row->{author}}{dist}{$row->{dist}}++;
        $authors{$row->{author}}{dists}++   if($authors{$row->{author}}{dist}{$row->{dist}} == 1);

        $self->{counts}{$date}{authors}{$row->{author}}++;
        $self->{counts}{$date}{distros}{$row->{dist}}++;

        $self->{counts}{$date}{newauthors}++  if($authors{$row->{author}}{count} == 1);
        $self->{counts}{$date}{newdistros}++  if($distros{$row->{dist}}{count} == 1);

        $self->{pause}{$date}++;
    }

    my $directory = $self->{parent}->directory;
    my $results   = "$directory/stats";
    mkpath($results);

    my $stat6  = IO::File->new("$results/stats6.txt",'w+')     or die "Cannot write to file [$results/stats6.txt]: $!\n";
    print $stat6 "#DATE,AUTHORS,DISTROS\n";
    my $stat12 = IO::File->new("$results/stats12.txt",'w+')    or die "Cannot write to file [$results/stats12.txt]: $!\n";
    print $stat12 "#DATE,AUTHORS,DISTROS\n";

    for my $date (sort keys %{ $self->{counts} }) {
        my $authors = scalar(keys %{ $self->{counts}{$date}{authors} });
        my $distros = scalar(keys %{ $self->{counts}{$date}{distros} });

        $self->{counts}{$date}{newauthors} ||= 0;
        $self->{counts}{$date}{newdistros} ||= 0;

        print $stat6  "$date,$authors,$distros\n";
        print $stat12 "$date,$self->{counts}{$date}{newauthors},$self->{counts}{$date}{newdistros}\n";

#        print $stat6  "$date,$authors\n";
#        print $stat7  "$date,$distros\n";
#        print $stat12 "$date,$self->{counts}{$date}{newauthors}\n";
#        print $stat13 "$date,$self->{counts}{$date}{newdistros}\n";
    }

    $stat6->close;
#    $stat7->close;
    $stat12->close;
#    $stat13->close;

    $self->_writepage('trends',\%tvars);


    $self->{parent}->_log("building cpan leader page");

    my $query = 'SELECT x.author,COUNT(x.dist) AS count FROM ixlatest AS x '.
                'INNER JOIN uploads AS u ON u.dist=x.dist AND u.version=x.version '.
                "WHERE u.type != 'backpan' GROUP BY x.author";
    my @latest = $self->{parent}->{CPANSTATS}->get_query('hash',$query);
    my (@allcurrent,@alluploads,@allrelease,@alldistros);
    my $inx = 1;
    for my $latest (sort {$b->{count} <=> $a->{count}} @latest) {
        push @allcurrent, {inx => $inx++, count => $latest->{count}, name => $latest->{author}};
        last    if($inx > 20);
    }

    $inx = 1;
    for my $author (sort {$authors{$b}{dists} <=> $authors{$a}{dists}} keys %authors) {
        push @alluploads, {inx => $inx++, count => $authors{$author}{dists}, name => $author};
        last    if($inx > 20);
    }

    $inx = 1;
    for my $author (sort {$authors{$b}{count} <=> $authors{$a}{count}} keys %authors) {
        push @allrelease, {inx => $inx++, count => $authors{$author}{count}, name => $author};
        last    if($inx > 20);
    }

    $inx = 1;
    for my $distro (sort {$distros{$b}{count} <=> $distros{$a}{count}} keys %distros) {
        push @alldistros, {inx => $inx++, count => $distros{$distro}{count}, name => $distro};
        last    if($inx > 20);
    }

    $tvars{allcurrent} = \@allcurrent;
    $tvars{alluploads} = \@alluploads;
    $tvars{allrelease} = \@allrelease;
    $tvars{alldistros} = \@alldistros;

    $self->_writepage('leadercpan',\%tvars);


    $self->{parent}->_log("building cpan interesting stats page");

    $tvars{authors}{total} = $self->_count_mailrc();
    my @rows = $self->{parent}->{CPANSTATS}->get_query('array',"SELECT COUNT(distinct author) FROM uploads");
    $tvars{authors}{active}   = $rows[0]->[0];
    $tvars{authors}{inactive} = $tvars{authors}{total} - $rows[0]->[0];

    @rows = $self->{parent}->{CPANSTATS}->get_query('array',"SELECT COUNT(distinct dist) FROM uploads WHERE type != 'backpan'");
    $tvars{distros}{uploaded1} = $rows[0]->[0];
    $self->{count}{distros}    = $rows[0]->[0];
    @rows = $self->{parent}->{CPANSTATS}->get_query('array',"SELECT COUNT(distinct dist) FROM uploads");
    $tvars{distros}{uploaded2} = $rows[0]->[0];
    $tvars{distros}{uploaded3} = $tvars{distros}{uploaded2} - $tvars{distros}{uploaded1};

    @rows = $self->{parent}->{CPANSTATS}->get_query('array',"SELECT COUNT(*) FROM uploads WHERE type != 'backpan'");
    $tvars{distros}{uploaded4} = $rows[0]->[0];
    @rows = $self->{parent}->{CPANSTATS}->get_query('array',"SELECT COUNT(*) FROM uploads");
    $tvars{distros}{uploaded5} = $rows[0]->[0];
    $tvars{distros}{uploaded6} = $tvars{distros}{uploaded5} - $tvars{distros}{uploaded4};


    $self->{parent}->_log("building cpan interesting stats page (part 2)");

    my (%stats,%dists,%pause,%last);
    $next = $self->{parent}->{CPANSTATS}->iterator('hash','SELECT * FROM uploads ORDER BY released');
    while(my $row = $next->()) {
        $stats{vcounter}++;
        if($stats{vcounter} % 10000 == 0) {
            $stats{'uploads'}{$stats{vcounter}}{dist} = $row->{dist};
            $stats{'uploads'}{$stats{vcounter}}{vers} = $row->{version};
            $stats{'uploads'}{$stats{vcounter}}{date} = $row->{released};
            $stats{'uploads'}{$stats{vcounter}}{name} = $row->{author};
        }

        $last{'uploads'}{counter} = $stats{vcounter};
        $last{'uploads'}{dist} = $row->{dist};
        $last{'uploads'}{vers} = $row->{version};
        $last{'uploads'}{date} = $row->{released};
        $last{'uploads'}{name} = $row->{author};

        unless($pause{$row->{author}}) {
            $pause{$row->{author}} = 1;
            $stats{pcounter}++;
            if($stats{pcounter} % 1000 == 0) {
                $stats{'uploaders'}{$stats{pcounter}}{dist} = $row->{dist};
                $stats{'uploaders'}{$stats{pcounter}}{vers} = $row->{version};
                $stats{'uploaders'}{$stats{pcounter}}{date} = $row->{released};
                $stats{'uploaders'}{$stats{pcounter}}{name} = $row->{author};
            }

            $last{'uploaders'}{counter} = $stats{pcounter};
            $last{'uploaders'}{dist} = $row->{dist};
            $last{'uploaders'}{vers} = $row->{version};
            $last{'uploaders'}{date} = $row->{released};
            $last{'uploaders'}{name} = $row->{author};
        }

        next    if($dists{$row->{dist}});

        $dists{$row->{dist}} = 1;
        $stats{dcounter}++;
        if($stats{dcounter} % 5000 == 0) {
            $stats{'distributions'}{$stats{dcounter}}{dist} = $row->{dist};
            $stats{'distributions'}{$stats{dcounter}}{vers} = $row->{version};
            $stats{'distributions'}{$stats{dcounter}}{date} = $row->{released};
            $stats{'distributions'}{$stats{dcounter}}{name} = $row->{author};
        }

        $last{'distributions'}{counter} = $stats{dcounter};
        $last{'distributions'}{dist} = $row->{dist};
        $last{'distributions'}{vers} = $row->{version};
        $last{'distributions'}{date} = $row->{released};
        $last{'distributions'}{name} = $row->{author};
    }

    for my $type (qw(distributions uploads uploaders)) {
        my @list;
        $stats{$type}{$last{$type}{counter}} = $last{$type};
        for my $count (sort {$a <=> $b} keys %{$stats{$type}}) {
            my @date = localtime($stats{$type}{$count}{date});
            my $date = sprintf "%04d-%02d-%02d %02d:%02d:%02d", $date[5]+1900, $date[4]+1, $date[3], $date[2], $date[1], $date[0] ;
            $stats{$type}{$count}{counter} = $count;
            $stats{$type}{$count}{date} = $date;
            push @list, $stats{$type}{$count};
        }
        $tvars{$type} = \@list  if(@list);
    }

    $self->_writepage('statscpan',\%tvars);
}

sub _no_reports {
    my $self  = shift;
    my $grace = time - 2419200;
    my $query =
        'SELECT x.*,count(s.id) as count FROM ixlatest AS x '.
        'LEFT JOIN release_summary AS s ON (x.dist=s.dist AND x.version=s.version) '.
        'GROUP BY x.dist,x.version ORDER BY x.released DESC';
    my $next = $self->{parent}->{CPANSTATS}->iterator('hash',$query);
    my $noreports = $self->{parent}->noreports();

    my (@rows,%dists);
    while(my $row = $next->()) {
        next    if($noreports && $row->{dist} =~ /^$noreports$/);
        next    if($dists{$row->{dist}});
        $dists{$row->{dist}} = $row->{released};

        next    if($row->{count} > 0);
        next    if(!$row->{oncpan} || $row->{oncpan} != 1);
        next    if($row->{released} > $grace);

        my @dt = localtime($row->{released});
        $row->{datetime} = sprintf "%04d-%02d-%02d", $dt[5]+1900,$dt[4]+1,$dt[3];
        $row->{display} = 1;
        push @rows, $row;
    }

    my $tvars = { rows => \@rows, rowcount => scalar(@rows) };
    $self->_writepage('noreports',$tvars);
}

sub _missing_in_action {
    my $self = shift;
    my (%tvars,%missing,@missing);

    $self->{parent}->_log("building missing in action page");

    my $missing = $self->{parent}->missing();
    return  unless(-f $missing);
    my $fh = IO::File->new($missing) or return;
    while(<$fh>) {
        chomp;
        my ($pauseid,$timestamp,$reason) = /^([a-z]+)[ \t]+([^+]+\+0[01]00) (.*)/i;
        next    unless($pauseid);
        $reason =~ s/</&lt;/g;
        $reason =~ s/>/&gt;/g;
        $missing{$pauseid}{timestamp} = $timestamp;
        $missing{$pauseid}{reason} = $reason;
    }
    $fh->close;

    for my $pauseid (sort keys %missing) {
        push @missing, { pauseid => $pauseid, timestamp => $missing{$pauseid}{timestamp},  reason => $missing{$pauseid}{reason} };
    }

    $tvars{missing} = \@missing if(@missing);
    $self->_writepage('missing',\%tvars);
}

sub _build_osname_matrix {
    my $self = shift;

    my %tvars = (template => 'osmatrix', FULL => 1, MONTH => 0);
    $self->{parent}->_log("building OS matrix - 1");
    my $CONTENT = $self->_osname_matrix($self->{versions},'all',1);
    $tvars{CONTENT} = $CONTENT;
    $self->_writepage('osmatrix-full',\%tvars);

    %tvars = (template => 'osmatrix', FULL => 1, MONTH => 0, layout => 'layout-wide');
    $tvars{CONTENT} = $CONTENT;
    $self->{parent}->_log("building OS matrix - 2");
    $self->_writepage('osmatrix-full-wide',\%tvars);

    %tvars = (template => 'osmatrix', FULL => 1, MONTH => 1);
    $self->{parent}->_log("building OS matrix - 3");
    $CONTENT = $self->_osname_matrix($self->{versions},'month',1);
    $tvars{CONTENT} = $CONTENT;
    $self->_writepage('osmatrix-full-month',\%tvars);

    %tvars = (template => 'osmatrix', FULL => 1, MONTH => 1, layout => 'layout-wide');
    $tvars{CONTENT} = $CONTENT;
    $self->{parent}->_log("building OS matrix - 4");
    $self->_writepage('osmatrix-full-month-wide',\%tvars);

    my @vers = grep {!/^5\.(11|9|7)\./} @{$self->{versions}};

    %tvars = (template => 'osmatrix', FULL => 0, MONTH => 0);
    $self->{parent}->_log("building OS matrix - 5");
    $CONTENT = $self->_osname_matrix(\@vers,'all',0);
    $tvars{CONTENT} = $CONTENT;
    $self->_writepage('osmatrix',\%tvars);

    %tvars = (template => 'osmatrix', FULL => 0, MONTH => 0, layout => 'layout-wide');
    $tvars{CONTENT} = $CONTENT;
    $self->{parent}->_log("building OS matrix - 6");
    $self->_writepage('osmatrix-wide',\%tvars);

    %tvars = (template => 'osmatrix', FULL => 0, MONTH => 1);
    $self->{parent}->_log("building OS matrix - 7");
    $CONTENT = $self->_osname_matrix(\@vers,'month',0);
    $tvars{CONTENT} = $CONTENT;
    $self->_writepage('osmatrix-month',\%tvars);

    %tvars = (template => 'osmatrix', FULL => 0, MONTH => 1, layout => 'layout-wide');
    $tvars{CONTENT} = $CONTENT;
    $self->{parent}->_log("building OS matrix - 8");
    $self->_writepage('osmatrix-month-wide',\%tvars);
}

sub _osname_matrix {
    my $self = shift;
    my $vers = shift or return '';
    my $type = shift;
    my $full = shift || 0;
    return ''   unless(@$vers);

    my %totals;
    for my $osname (sort keys %{$self->{osys}}) {
        if($type eq 'month') {
            my $check = 0;
            for my $perl (@$vers) { $check++ if(defined $self->{osys}{$osname}{$perl}{$type}) }
            next    if($check == 0);
        }
        for my $perl (@$vers) {
            my $count = defined $self->{osys}{$osname}{$perl}{$type}
                            ? scalar(keys %{$self->{osys}{$osname}{$perl}{$type}})
                            : 0;
            $totals{os}{$osname} += $count;
            $totals{perl}{$perl} += $count;
        }
    }

    my $index = 0;
    my $content = 
        "\n"
        . '<table class="matrix" summary="OS/Perl Matrix">'
        . "\n"
        . '<tr><th>OS/Perl</th><th></th><th>' 
        . join( "</th><th>", @$vers ) 
        . '</th><th></th><th>OS/Perl</th></tr>'
        . "\n" 
        . '<tr><th></th><th class="totals">Totals</th><th class="totals">' 
        . join( '</th><th class="totals">', map {$totals{perl}{$_}||0} @$vers ) 
        . '</th><th class="totals">Totals</th><th></th></tr>';

    for my $osname (sort {$totals{os}{$b} <=> $totals{os}{$a}} keys %{$totals{os}}) {
        if($type eq 'month') {
            my $check = 0;
            for my $perl (@$vers) { $check++ if(defined $self->{osys}{$osname}{$perl}{$type}) }
            next    if($check == 0);
        }
        $content .= "\n" . '<tr><th>' . $osname . '</th><th class="totals">' . $totals{os}{$osname} . '</th>';
        for my $perl (@$vers) {
            my $count = defined $self->{osys}{$osname}{$perl}{$type}
                            ? scalar(keys %{$self->{osys}{$osname}{$perl}{$type}})
                            : 0;
            if($count) {
                if($self->{list}{osname}{$osname}{$perl}{$type}) {
                    $index = $self->{list}{osname}{$osname}{$perl}{$type};
                } else {
                    my %tvars = (template => 'distlist', OS => 1, MONTH => ($type eq 'month' ? 1 : 0), FULL => $full);
                    my @list = sort keys %{$self->{osys}{$osname}{$perl}{$type}};
                    $tvars{dists}     = \@list;
                    $tvars{vplatform} = $osname;
                    $tvars{vperl}     = $perl;
                    $tvars{count}     = $count;

                    $index = join('-','osys', $type, $osname, $perl);
                    $index =~ s/[^-.\w]/-/g;
                    $index = 'matrix/' . $index;
                    $self->{list}{osname}{$osname}{$perl}{$type} = $index;
                    $self->_writepage($index,\%tvars);
                }
            }

            my $number = $self->{osname}{$osname}{$perl}{$type} || 0;
            my $class = 'none';
            $class = 'some' if($number > 0);
            $class = 'more' if($number > $matrix_limits{$type}->[0]);
            $class = 'lots' if($number > $matrix_limits{$type}->[1]);
            $content .= qq{<td class="$class">}
                        . ($count ? qq|<a href="$index.html" title="Distribution List for $osname/$perl">$count</a><br />$self->{osname}{$osname}{$perl}{$type}| : '-')
                        . '</td>';
        }
        $content .= '<th class="totals">' . $totals{os}{$osname} . '</th><th>' . $osname . '</th>';
        $content .= '</tr>';
    }

    $content .= 
        "\n" 
        . '<tr><th></th><th class="totals">Totals</th><th class="totals">' 
        . join( '</th><th class="totals">', map {$totals{perl}{$_}||0} @$vers ) 
        . '</th><th class="totals">Totals</th><th></th></tr>'
        . "\n" 
        . '<tr><th>OS/Perl</th><th></th><th>' 
        . join( "</th><th>", @$vers ) 
        . '</th><th></th><th>OS/Perl</th></tr>'
        . "\n" . 
        '</table>';

    return $content;
}

sub _build_platform_matrix {
    my $self = shift;

    my %tvars = (template => 'pmatrix', FULL => 1, MONTH => 0);
    $self->{parent}->_log("building platform matrix - 1");
    my $CONTENT = $self->_platform_matrix($self->{versions},'all',1);
    $tvars{CONTENT} = $CONTENT;
    $self->_writepage('pmatrix-full',\%tvars);

    %tvars = (template => 'pmatrix', FULL => 1, MONTH => 0, layout => 'layout-wide');
    $tvars{CONTENT} = $CONTENT;
    $self->{parent}->_log("building platform matrix - 2");
    $self->_writepage('pmatrix-full-wide',\%tvars);

    %tvars = (template => 'pmatrix', FULL => 1, MONTH => 1);
    $self->{parent}->_log("building platform matrix - 3");
    $CONTENT = $self->_platform_matrix($self->{versions},'month',1);
    $tvars{CONTENT} = $CONTENT;
    $self->_writepage('pmatrix-full-month',\%tvars);

    %tvars = (template => 'pmatrix', FULL => 1, MONTH => 1, layout => 'layout-wide');
    $tvars{CONTENT} = $CONTENT;
    $self->{parent}->_log("building platform matrix - 4");
    $self->_writepage('pmatrix-full-month-wide',\%tvars);

    my @vers = grep {!/^5\.(11|9|7)\./} @{$self->{versions}};

    %tvars = (template => 'pmatrix', FULL => 0, MONTH => 0);
    $self->{parent}->_log("building platform matrix - 5");
    $CONTENT = $self->_platform_matrix(\@vers,'all',0);
    $tvars{CONTENT} = $CONTENT;
    $self->_writepage('pmatrix',\%tvars);

    %tvars = (template => 'pmatrix', FULL => 0, MONTH => 0, layout => 'layout-wide');
    $tvars{CONTENT} = $CONTENT;
    $self->{parent}->_log("building platform matrix - 6");
    $self->_writepage('pmatrix-wide',\%tvars);

    %tvars = (template => 'pmatrix', FULL => 0, MONTH => 1);
    $self->{parent}->_log("building platform matrix - 7");
    $CONTENT = $self->_platform_matrix(\@vers,'month',0);
    $tvars{CONTENT} = $CONTENT;
    $self->_writepage('pmatrix-month',\%tvars);

    %tvars = (template => 'pmatrix', FULL => 0, MONTH => 1, layout => 'layout-wide');
    $tvars{CONTENT} = $CONTENT;
    $self->{parent}->_log("building platform matrix - 8");
    $self->_writepage('pmatrix-month-wide',\%tvars);
}

sub _platform_matrix {
    my $self = shift;
    my $vers = shift or return '';
    my $type = shift;
    my $full = shift || 0;
    return ''   unless(@$vers);

    my %totals;
    for my $platform (sort keys %{$self->{pass}}) {
        if($type eq 'month') {
            my $check = 0;
            for my $perl (@$vers) { $check++ if(defined $self->{pass}{$platform}{$perl}{$type}) }
            next    if($check == 0);
        }
        for my $perl (@$vers) {
            my $count = defined $self->{pass}{$platform}{$perl}{$type}
                            ? scalar(keys %{$self->{pass}{$platform}{$perl}{$type}})
                            : 0;
            $totals{platform}{$platform} += $count;
            $totals{perl}{$perl} += $count;
        }
    }

    my $index = 0;
    my $content = 
        "\n" 
        . '<table class="matrix" summary="Platform/Perl Matrix">'
        . "\n" 
        . '<tr><th>Platform/Perl</th><th></th><th>' 
        . join( "</th><th>", @$vers ) 
        . '</th><th></th><th>Platform/Perl</th></tr>'
        . "\n" 
        . '<tr><th></th><th class="totals">Totals</th><th class="totals">' 
        . join( '</th><th class="totals">', map {$totals{perl}{$_}||0} @$vers ) 
        . '</th><th class="totals">Totals</th><th></th></tr>';

    for my $platform (sort {$totals{platform}{$b} <=> $totals{platform}{$a}} keys %{$totals{platform}}) {
        if($type eq 'month') {
            my $check = 0;
            for my $perl (@$vers) { $check++ if(defined $self->{pass}{$platform}{$perl}{$type}) }
            next    if($check == 0);
        }
        $content .= "\n" . '<tr><th>' . $platform . '</th><th class="totals">' . $totals{platform}{$platform} . '</th>';
        for my $perl (@$vers) {
            my $count = defined $self->{pass}{$platform}{$perl}{$type}
                            ? scalar(keys %{$self->{pass}{$platform}{$perl}{$type}})
                            : 0;
            if($count) {
                if($self->{list}{platform}{$platform}{$perl}{$type}) {
                    $index = $self->{list}{platform}{$platform}{$perl}{$type};
                } else {
                    my %tvars = (template => 'distlist', OS => 0, MONTH => ($type eq 'month' ? 1 : 0), FULL => $full);
                    my @list = sort keys %{$self->{pass}{$platform}{$perl}{$type}};
                    $tvars{dists}     = \@list;
                    $tvars{vplatform} = $platform;
                    $tvars{vperl}     = $perl;
                    $tvars{count}     = $count;

                    $index = join('-','platform', $type, $platform, $perl);
                    $index =~ s/[^-.\w]/-/g;
                    $index = 'matrix/' . $index;
                    $self->{list}{platform}{$platform}{$perl}{$type} = $index;
                    $self->_writepage($index,\%tvars);
                }
            }

            my $number = $self->{platform}{$platform}{$perl}{$type} || 0;
            my $class = 'none';
            $class = 'some' if($number > 0);
            $class = 'more' if($number > $matrix_limits{$type}->[0]);
            $class = 'lots' if($number > $matrix_limits{$type}->[1]);
            $content .= qq{<td class="$class">}
                        . ($count ? qq|<a href="$index.html" title="Distribution List for $platform/$perl">$count</a><br />$self->{platform}{$platform}{$perl}{$type}| : '-')
                        . '</td>';
        }
        $content .= '<th class="totals">' . $totals{platform}{$platform} . '</th><th>' . $platform . '</th>';
        $content .= '</tr>';
    }
    $content .= 
        "\n" 
        . '<tr><th></th><th class="totals">Totals</th><th class="totals">' 
        . join( '</th><th class="totals">', map {$totals{perl}{$_}||0} @$vers ) 
        . '</th><th class="totals">Totals</th><th></th></tr>'
        . "\n" 
        . '<tr><th>Platform/Perl</th><th></th><th>' 
        . join( "</th><th>", @$vers ) 
        . '</th><th></th><th>Platform/Perl</th></tr>'
        . "\n" 
        . '</table>';

    return $content;
}

# Notes:
# 
# * use a JSON store (e.g. cpanstats-platform.json)
# * find the last month stored
# * rebuild from last month to current month
# * store JSON data

sub _build_monthly_stats {
    my $self  = shift;
    my (%tvars,%stats,%testers,%monthly);
    my %templates = (
        platform    => 'mplatforms',
        osname      => 'mosname',
        perl        => 'mperls',
        tester      => 'mtesters'
    );

    $self->{parent}->_log("building monthly tables");

    my $query = q!SELECT postdate,%s,count(id) AS count FROM cpanstats ! .
                q!WHERE type = 2 %s ! .
                q!GROUP BY postdate,%s ORDER BY postdate,count DESC!;

    for my $type (qw(platform osname perl)) {
        $self->{parent}->_log("building monthly $type table");
        (%tvars,%stats,%monthly) = ();
        my $postdate = '';

        my $storage = sprintf $self->{parent}->monthstore(), $type;
        if(-f $storage) {
            my $data = read_file($storage);
            my $json = decode_json($data);

            my $last = 0;
            for my $date (keys %{ $json->{monthly} }) {
                $last = $date if($date > $last);
            }

            delete $json->{$_}{$last} for(qw(monthly stats));

            %monthly = %{ $json->{monthly} };
            %stats   = %{ $json->{stats}   };

            $postdate = "AND postdate >= '$last'" if($last);
        }

        my $sql = sprintf $query, $type, $postdate, $type;
        my $next = $self->{parent}->{CPANSTATS}->iterator('hash',$sql);
        while(my $row = $next->()) {
            $monthly{$row->{postdate}}{$type}{$row->{$type}} = 1;
            $row->{$type} = $self->{parent}->osname($row->{$type})  if($type eq 'osname');
            push @{$stats{$row->{postdate}}{list}}, "[$row->{count}] $row->{$type}";
        }

        for my $date (sort {$b <=> $a} keys %stats) {
            $stats{$date}{count} = scalar(@{$stats{$date}{list}});
            push @{$tvars{STATS}}, [$date,$stats{$date}{count},join(', ',@{$stats{$date}{list}})];
        }
        $self->_writepage($templates{$type},\%tvars);

        # remember monthly counts for monthly files later
        for my $date (keys %monthly) {
            $self->{monthly}{$date}{$type} = keys %{ $monthly{$date}{$type} };
        }

        # store data
        my $json = { monthly => \%monthly, stats => \%stats };
        my $data = encode_json($json);
        write_file($storage,$data);
    }

    {
        my $type = 'tester';
        $self->{parent}->_log("building monthly $type table");
        (%tvars,%stats,%monthly) = ();
        my $postdate = '';

        my $storage = sprintf $self->{parent}->monthstore(), $type;
        if(-f $storage) {
            my $data = read_file($storage);
            my $json = decode_json($data);

            my $last = 0;
            for my $date (keys %{ $json->{monthly} }) {
                $last = $date if($date > $last);
            }

            delete $json->{$_}{$last} for(qw(monthly stats));

            %monthly = %{ $json->{monthly} };
            %stats   = %{ $json->{stats}   };

            $postdate = "AND postdate >= '$last'" if($last);
        }

        my $sql = sprintf $query, $type, $postdate, $type;
        my $next = $self->{parent}->{CPANSTATS}->iterator('hash',$sql);
        while(my $row = $next->()) {
            my $name = $self->_tester_name($row->{tester});
            $testers{$name}                         += $row->{count};
            $stats{$row->{postdate}}{list}{$name}   += $row->{count};
            $monthly{$row->{postdate}}{$type}{$name} = 1;
        }

        for my $date (sort {$b <=> $a} keys %stats) {
            $stats{$date}{count} = keys %{$stats{$date}{list}};
            push @{$tvars{STATS}}, [$date,$stats{$date}{count},
                join(', ',
                    map {"[$stats{$date}{list}{$_}] $_"}
                        sort {$stats{$date}{list}{$b} <=> $stats{$date}{list}{$a}}
                            keys %{$stats{$date}{list}})];
        }
        $self->_writepage($templates{$type},\%tvars);

        # remember monthly counts for monthly files later
        for my $date (keys %monthly) {
            $self->{monthly}{$date}{$type} = keys %{ $monthly{$date}{$type} };
        }

        # store data
        my $json = { monthly => \%monthly, stats => \%stats };
        my $data = encode_json($json);
        write_file($storage,$data);
    }
}

sub _build_osname_leaderboards {
    my $self = shift;
    my ($json,$data);

    $self->{parent}->_log("building osname leaderboards");

    # load data
    my $storage = $self->{parent}->leadstore();
    if($storage && -f $storage) {
        $json = read_file($storage);
        $data = decode_json($json);
    }

    unless($data) {
        $data->{'999999'} = {}, # all counter
        $data->{'199908'} = {}  # first report date
    }

    # set dates
    my $post0 = '999999';
    my $post1 = $self->{dates}{LASTDATE};
    my $post2 = $self->{dates}{THISDATE};
    my $post3 = $self->{dates}{THISDATE} + 1;
    $post1 += 88    if($post3 % 100 > 12);

    $self->{parent}->_log("1.post0=$post0");
    $self->{parent}->_log("2.post1=$post1");
    $self->{parent}->_log("3.post2=$post2");
    $self->{parent}->_log("4.post3=$post3");

    my @posts = sort keys %$data;
    $self->{parent}->_log("5.posts[0]=$posts[0]");

    if($posts[0] != $post1) {
        my $p = $posts[0];
        while($p <= $post3) {
            $data->{$p} = $self->_build_os_hash($p);
            $p++;
            $p += 88    if($p % 100 > 12);
        }
    } else {
        for my $p ($post1,$post2,$post3) {
            $data->{$p} = $self->_build_os_hash($p);
        }
    }

    my %oses;
    for my $post (keys %$data) {
        if($post == $post0 || $post == $post1 || $post == $post2 || $post == $post3) {
            for my $os (keys %{$data->{$post}}) {
                next    unless($os);
                $oses{$os} = 1;
                for my $tester (keys %{$data->{$post}{$os}}) {
                    $data->{$post0}{$os}{$tester} ||= 0;  # make sure we include all testers
                }
            }
        } else {
            for my $os (keys %{$data->{$post}}) {
                next    unless($os);
                $oses{$os} = 1;
                for my $tester (keys %{$data->{$post}{$os}}) {
                    $data->{$post0}{$os}{$tester} += $data->{$post}{$os}{$tester};
                }
            }
            delete $data->{$post};
        }
    }

    # save data
    if($storage) {
        $json = encode_json($data);
        write_file($storage,$json);
    }

    # reorganise data
    my %hash;
    for my $os (keys %oses) {
        for my $tester (keys %{$data->{$post0}{$os}}) {
            $hash{$os}{$tester}{this} =  $data->{$post3}{$os}{$tester} || 0;
            $hash{$os}{$tester}{that} =  $data->{$post2}{$os}{$tester} || 0;
            $hash{$os}{$tester}{all}  = ($data->{$post3}{$os}{$tester} || 0) + ($data->{$post2}{$os}{$tester} || 0) + 
                                        ($data->{$post1}{$os}{$tester} || 0) + ($data->{$post0}{$os}{$tester} || 0);
        }

    }

    $self->{parent}->_log("1.reorg");

    my %titles = (
        this    => 'This Month',
        that    => 'Last Month',
        all     => 'All Months'
    );

    my $sql = 'SELECT * FROM osname ORDER BY ostitle';
    my @rows = $self->{parent}->{CPANSTATS}->get_query('hash',$sql);
    my @oses = grep {$_->{osname}} @rows;

    for my $osname (keys %oses) {
        next    unless($osname);
        for my $type (qw(this that all)) {
            my @leaders;
            for my $tester (sort {($hash{$osname}{$b}{$type} || 0) <=> ($hash{$osname}{$a}{$type} || 0) || $a cmp $b} keys %{$hash{$osname}}) {
                push @leaders, 
                        {   col2    => $hash{$osname}{$tester}{this}, 
                            col1    => $hash{$osname}{$tester}{that},
                            col3    => $hash{$osname}{$tester}{all},
                            tester  => $tester
                        } ;
            }

            my $os = lc $osname;

            my %tvars;
            $tvars{osnames}     = \@oses;
            $tvars{template}    = 'leaderos';
            $tvars{osname}      = $self->{parent}->osname($osname);
            $tvars{leaders}     = \@leaders;
            $tvars{headers}     = { col1 => $post2, col2 => $post3, title => "$tvars{osname} Leaderboard ($titles{$type})" };
            $tvars{links}{this} = $type eq 'this' ? '' : "leaders-$os-this.html";
            $tvars{links}{that} = $type eq 'that' ? '' : "leaders-$os-that.html";
            $tvars{links}{all}  = $type eq 'all'  ? '' : "leaders-$os-all.html";
            $self->{parent}->_log("1.leaders/leaders-$os-$type");

            $self->_writepage("leaders/leaders-$os-$type",\%tvars);
        }
    }

    $self->{parent}->_log("building leader board");
    my (%tvars,%stats,%testers) = ();

    $tvars{osnames} = \@oses;
    for my $os (keys %{$data->{$post0}}) {
        next    unless($os);
        for my $tester (keys %{$data->{$post0}{$os}}) {
            $testers{$tester} += $data->{$post0}{$os}{$tester};
        }
    }

    my $count = 1;
    for my $tester (sort {$testers{$b} <=> $testers{$a} || $a cmp $b} keys %testers) {
        push @{$tvars{STATS}}, [$count++, $testers{$tester}, $tester];
    }

    $count--;

    $self->{parent}->_log("Unknown Addresses: ".($count-$known_t));
    $self->{parent}->_log("Known Addresses:   ".($known_s));
    $self->{parent}->_log("Listed Addresses:  ".($known_s+$count-$known_t));
    $self->{parent}->_log("Unknown Testers:   ".($count-$known_t));
    $self->{parent}->_log("Known Testers:     ".($known_t));
    $self->{parent}->_log("Listed Testers:    ".($count));

    push @{$tvars{COUNTS}}, ($count-$known_t),$known_s,($known_s+$count-$known_t),($count-$known_t),$known_t,$count;

    $self->_writepage('testers',\%tvars);
}

sub _build_os_hash {
    my ($self,$pd) = @_;
    my %hash;

    my $sql = 
        'SELECT osname,tester,COUNT(id) AS count FROM cpanstats '.
        'WHERE postdate=? AND type=2 '.
        'GROUP BY osname,tester';

    my $next = $self->{parent}->{CPANSTATS}->iterator('hash',$sql,$pd);
    while(my $row = $next->()) {
        my $name = $self->_tester_name($row->{tester});
        $hash{$row->{osname}}{$name} += $row->{count};
    }

    return \%hash;
}

sub _build_monthly_stats_files {
    my $self   = shift;
    my %tvars;

    my $directory = $self->{parent}->directory;
    my $results   = "$directory/stats";
    mkpath($results);

    $self->{parent}->_log("building monthly stats for graphs - 1,3,pcent1");

    #print "DATE,UPLOADS,REPORTS,NA,PASS,FAIL,UNKNOWN\n";
    my $fh1 = IO::File->new(">$results/stats1.txt");
    print $fh1 "#DATE,UPLOADS,REPORTS,PASS,FAIL\n";

    my $fh2 = IO::File->new(">$results/pcent1.txt");
    print $fh2 "#DATE,FAIL,OTHER,PASS\n";

    my $fh3 = IO::File->new(">$results/stats3.txt");
    print $fh3 "#DATE,FAIL,NA,UNKNOWN\n";

    for my $date (sort keys %{$self->{stats}}) {
        next    if($date > $self->{dates}{LIMIT});

        my $uploads = ($self->{pause}{$date}              || 0);
        my $reports = ($self->{stats}{$date}{reports}     || 0);
        my $passes  = ($self->{stats}{$date}{state}{pass} || 0);
        my $fails   = ($self->{stats}{$date}{state}{fail} || 0);
        my $others  = $reports - $passes - $fails;

        my @fields = (
            $date, $uploads, $reports, $passes, $fails
        );

        my @pcent = (
            $date,
            ($reports > 0 ? int($fails  / $reports * 100) : 0),
            ($reports > 0 ? int($others / $reports * 100) : 0),
            ($reports > 0 ? int($passes / $reports * 100) : 0)
        );

        unshift @{$tvars{STATS}},
            [   @fields,
                $self->{stats}{$date}{state}{na},
                $self->{stats}{$date}{state}{unknown}];

        # graphs don't include current month
        next    if($date > $self->{dates}{LIMIT}-1);

        my $content = sprintf "%d,%d,%d,%d,%d\n", @fields;
        print $fh1 $content;

        $content = sprintf "%d,%d,%d,%d\n", @pcent;
        print $fh2 $content;

        $content = sprintf "%d,%d,%d,%d\n",
            $date,
            ($self->{stats}{$date}{state}{fail}    || 0),
            ($self->{stats}{$date}{state}{na}      || 0),
            ($self->{stats}{$date}{state}{unknown} || 0);
        print $fh3 $content;
    }
    $fh1->close;
    $fh2->close;
    $fh3->close;

    $self->_writepage('mreports',\%tvars);

    $self->{parent}->_log("building monthly stats for graphs - 2");

    #print "DATE,TESTERS,PLATFORMS,PERLS\n";
    $fh2 = IO::File->new(">$results/stats2.txt");
    print $fh2 "#DATE,TESTERS,PLATFORMS,PERLS\n";

    for my $date (sort keys %{$self->{stats}}) {
        next    if($date > $self->{dates}{LIMIT}-1);
        printf $fh2 "%d,%d,%d,%d\n",
            $date,
            ($self->{monthly}{$date}{tester}   || 0),
            ($self->{monthly}{$date}{platform} || 0),
            ($self->{monthly}{$date}{perl}     || 0);
    }
    $fh2->close;

    $self->{parent}->_log("building monthly stats for graphs - 4");

    #print "DATE,ALL,FIRST,LAST\n";
    $fh1 = IO::File->new(">$results/stats4.txt");
    print $fh1 "#DATE,ALL,FIRST,LAST\n";

    for my $date (sort keys %{ $self->{stats} }) {
        next    if($date > $self->{dates}{LIMIT}-1);

        if(defined $self->{counts}{$date}) {
            $self->{counts}{$date}{all} = scalar(keys %{$self->{counts}{$date}{testers}});
        }
        $self->{counts}{$date}{all}   ||= 0;
        $self->{counts}{$date}{first} ||= 0;
        $self->{counts}{$date}{last}  ||= 0;
        $self->{counts}{$date}{last}    = ''  if($date > $self->{dates}{THISDATE});

        printf $fh1 "%d,%s,%s,%s\n",
            $date,
            $self->{counts}{$date}{all},
            $self->{counts}{$date}{first},
            $self->{counts}{$date}{last};
    }
    $fh1->close;
}

sub _build_failure_rates {
    my $self  = shift;
    my (%tvars,%dists);

    $self->{parent}->_log("building failure rates");

    my $query =
        'SELECT x.dist,x.version,u.released FROM ixlatest AS x '.
        'INNER JOIN uploads AS u ON u.dist=x.dist AND u.version=x.version '.
        "WHERE u.type != 'backpan'";
    my $next = $self->{parent}->{CPANSTATS}->iterator('hash',$query);
    while(my $row = $next->()) {
        $dists{$row->{dist}}{$row->{version}} = $row->{released};
    }

    $self->{parent}->_log("selecting failure rates");

    # select worst failure rates - latest version, and ignoring backpan only.
    my %worst;
    for my $dist (keys %{ $self->{fails} }) {
        next    unless($dists{$dist});
        my ($version) = sort {$dists{$dist}{$b} <=> $dists{$dist}{$a}} keys %{$dists{$dist}};

        $worst{"$dist-$version"} = $self->{fails}->{$dist}{$version};
        $worst{"$dist-$version"}->{dist}   = $dist;
        $worst{"$dist-$version"}->{pcent}  = $self->{fails}{$dist}{$version}{fail}
                                                ? int(($self->{fails}{$dist}{$version}{fail}/$self->{fails}{$dist}{$version}{total})*10000)/100
                                                : 0.00;
        $worst{"$dist-$version"}->{pass} ||= 0;
        $worst{"$dist-$version"}->{fail} ||= 0;

        my @post = localtime($dists{$dist}{$version});
        $worst{"$dist-$version"}->{post} = sprintf "%04d%02d", $post[5]+1900, $post[4]+1;
    }

    $self->{parent}->_log("worst = " . scalar(keys %worst) . " entries");
    $self->{parent}->_log("building failure counts");

    # calculate worst failure rates - by failure count
    my $count = 1;
    for my $dist (sort {$worst{$b}->{fail} <=> $worst{$a}->{fail} || $worst{$b}->{pcent} <=> $worst{$a}->{pcent}} keys %worst) {
        last unless($worst{$dist}->{fail});
        my $pcent = sprintf "%3.2f%%", $worst{$dist}->{pcent};
        push @{$tvars{WORST}}, [$count++, $worst{$dist}->{fail}, $dist, $worst{$dist}->{post}, $worst{$dist}->{pass}, $worst{$dist}->{total}, $pcent, $worst{$dist}->{dist}];
        last    if($count > 100);
    }

    my $database  = $self->{parent}->database;
    my $mtime = (stat($database))[9];
    my @ltime = localtime($mtime);
    $self->{DATABASE2} = sprintf "%d%s %s %d", $ltime[3],_ext($ltime[3]),$month{$ltime[4]},$ltime[5]+1900;

    $tvars{DATABASE} = $self->{DATABASE2};
    $self->_writepage('wdists',\%tvars);
    undef %tvars;

    $self->{parent}->_log("building failure pecentages");

    # calculate worst failure rates - by percentage
    $count = 1;
    for my $dist (sort {$worst{$b}->{pcent} <=> $worst{$a}->{pcent} || $worst{$b}->{fail} <=> $worst{$a}->{fail}} keys %worst) {
        last unless($worst{$dist}->{fail});
        my $pcent = sprintf "%3.2f%%", $worst{$dist}->{pcent};
        push @{$tvars{WORST}}, [$count++, $worst{$dist}->{fail}, $dist, $worst{$dist}->{post}, $worst{$dist}->{pass}, $worst{$dist}->{total}, $pcent, $worst{$dist}->{dist}];
        last    if($count > 100);
    }

    $tvars{DATABASE} = $self->{DATABASE2};
    $self->_writepage('wpcent',\%tvars);
    undef %tvars;

    $self->{parent}->_log("done building failure rates");

    # now we do as above but for the last 6 months

    my @recent = localtime(time() - 15778463); # 6 months ago
    my $recent = sprintf "%04d%02d", $recent[5]+1900, $recent[4]+1;

    for my $dist (keys %worst) {
        next    if($worst{$dist}->{post} ge $recent);
        delete $worst{$dist};
    }

    # calculate worst failure rates - by failure count
    $count = 1;
    for my $dist (sort {$worst{$b}->{fail} <=> $worst{$a}->{fail} || $worst{$b}->{pcent} <=> $worst{$a}->{pcent}} keys %worst) {
        last unless($worst{$dist}->{fail});
        my $pcent = sprintf "%3.2f%%", $worst{$dist}->{pcent};
        push @{$tvars{WORST}}, [$count++, $worst{$dist}->{fail}, $dist, $worst{$dist}->{post}, $worst{$dist}->{pass}, $worst{$dist}->{total}, $pcent, $worst{$dist}->{dist}];
        last    if($count > 100);
    }

    $database  = $self->{parent}->database;
    $mtime = (stat($database))[9];
    @ltime = localtime($mtime);
    $self->{DATABASE2} = sprintf "%d%s %s %d", $ltime[3],_ext($ltime[3]),$month{$ltime[4]},$ltime[5]+1900;

    $tvars{DATABASE} = $self->{DATABASE2};
    $self->_writepage('wdists-recent',\%tvars);
    undef %tvars;

    $self->{parent}->_log("building failure pecentages");

    # calculate worst failure rates - by percentage
    $count = 1;
    for my $dist (sort {$worst{$b}->{pcent} <=> $worst{$a}->{pcent} || $worst{$b}->{fail} <=> $worst{$a}->{fail}} keys %worst) {
        last unless($worst{$dist}->{fail});
        my $pcent = sprintf "%3.2f%%", $worst{$dist}->{pcent};
        push @{$tvars{WORST}}, [$count++, $worst{$dist}->{fail}, $dist, $worst{$dist}->{post}, $worst{$dist}->{pass}, $worst{$dist}->{total}, $pcent, $worst{$dist}->{dist}];
        last    if($count > 100);
    }

    $tvars{DATABASE} = $self->{DATABASE2};
    $self->_writepage('wpcent-recent',\%tvars);
}

sub _build_performance_stats {
    my $self  = shift;

    my $directory = $self->{parent}->directory;
    my $results   = "$directory/stats";
    mkpath($results);

    $self->{parent}->_log("building peformance stats for graphs");

    my $fh = IO::File->new(">$results/build1.txt");
    print $fh "#DATE,REQUESTS,PAGES,REPORTS\n";

    for my $date (sort {$a <=> $b} keys %{$self->{build}}) {
#$self->{parent}->_log("build_stats: date=$date, old=$self->{build}{$date}->{old}");
	next	if($self->{build}{$date}->{old} == 2);	# ignore todays tally
        #next    if($date > $self->{dates}{LIMIT}-1);

        printf $fh "%d,%d,%d,%d\n",
            $date,
            ($self->{build}{$date}{webtotal}  || 0),
            ($self->{build}{$date}{webunique} || 0),
            ($self->{build}{$date}{reports}   || 0);
    }
    $fh->close;
}


=item * _writepage

Creates a single HTML page.

=cut

sub _writepage {
    my ($self,$page,$vars) = @_;
    my $directory = $self->{parent}->directory;
    my $templates = $self->{parent}->templates;

    #$self->{parent}->_log("_writepage: page=$page");

    my $template = $vars->{template} || $page;
    my $tlayout  = $vars->{layout} || 'layout';
    my $layout   = "$tlayout.html";
    my $source   = "$template.html";
    my $target   = "$directory/$page.html";
    mkdir(dirname($target));

    #$self->{parent}->_log("_writepage: layout=$layout, source=$source, target=$target");

    $vars->{SOURCE}     = $source;
    $vars->{VERSION}    = $VERSION;
    $vars->{RUNDATE}    = $self->{dates}{RUNDATE};
    $vars->{RUNTIME}    = $self->{dates}{RUNTIME};
    $vars->{STATDATE}   = $self->{dates}{STATDATE};
    $vars->{THATDATE}   = $self->{dates}{THATDATE};
    $vars->{SHORTDATE}  = $self->{dates}{SHORTDATE};
    $vars->{copyright}  = $self->{parent}->copyright;

#    if($page =~ /^(p|os)matrix/) {
#        use Data::Dumper;
#        print STDERR "$page:" . Dumper($vars);
#    }

    my %config = (                          # provide config info
        RELATIVE        => 1,
        ABSOLUTE        => 1,
        INCLUDE_PATH    => $templates,
        INTERPOLATE     => 0,
        POST_CHOMP      => 1,
        TRIM            => 1,
    );

    my $parser = Template->new(\%config);   # initialise parser
    $parser->process($layout,$vars,$target) # parse the template
        or die $parser->error() . "\n";
}

=item * _tester_name

Returns either the known name of the tester for the given email address, or
returns a doctored version of the address for displaying in HTML.

=cut

my $address;
sub _tester_name {
    my ($self,$name) = @_;

    $address ||= do {
        my (%address_map,%known);
        my $address = $self->{parent}->address;

        my $fh = IO::File->new($address)    or die "Cannot open address file [$address]: $!";
        while(<$fh>) {
            chomp;
            my ($source,$target) = (/(.*),(.*)/);
            next    unless($source && $target);
            $address_map{$source} = $target;
            $known{$target}++;
        }
        $fh->close;
        $known_t = scalar(keys %known);
        $known_s = scalar(keys %address_map);
        \%address_map;
    };

    my $addr = ($address->{$name} && $address->{$name} =~ /\&\#x?\d+\;/)
                ? $address->{$name}
                : encode_entities( ($address->{$name} || $name) );
    $addr =~ s/\./ /g if($addr =~ /\@/);
    $addr =~ s/\@/ \+ /g;
    $addr =~ s/</&lt;/g;
    return $addr;
}

# Provides the ordinal for dates.

sub _ext {
    my $num = shift;
    return 'st' if($num == 1 || $num == 21 || $num == 31);
    return 'nd' if($num == 2 || $num == 22);
    return 'rd' if($num == 3 || $num == 23);
    return 'th';
}

sub _parsedate {
    my $time = shift;
    my @time = localtime($time);
    return sprintf "%04d%02d", $time[5]+1900,$time[4]+1;
}

sub _count_mailrc {
    my $self = shift;
    my $count = 0;
    my $mailrc = $self->{parent}->mailrc();

    my $fh  = IO::File->new($mailrc,'r')     or die "Cannot read file [$mailrc]: $!\n";
    while(<$fh>) {
        last    if(/^alias\s*DBIML/);
        $count++;
    }
    $fh->close;

    return $count;
}

q("Will code for Guinness!");

__END__

=back

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

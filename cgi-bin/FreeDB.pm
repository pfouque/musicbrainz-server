#____________________________________________________________________________
#
#   MusicBrainz -- the open internet music database
#
#   Copyright (C) 2000 Robert Kaye
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, write to the Free Software
#   Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#
#   $Id$
#____________________________________________________________________________
                                                                               
package FreeDB;
use TableBase;

BEGIN { require 5.003 }
use vars qw(@ISA @EXPORT);
@ISA    = @ISA    = 'TableBase';
@EXPORT = @EXPORT = '';

use strict;
use CDDBmb;
use Track;
use Album;
use Artist;
use Diskid;
use constant  CD_MSF_OFFSET => 150;
use constant  CD_FRAMES     =>  75;
use constant  CD_SECS       =>  60;

sub new
{
   my ($type, $dbh) = @_;

   my $this = TableBase->new($dbh);
   return bless $this, $type;
}

sub _lba_to_msf
{
    my ($lba) = @_;
    my ($m, $s, $f);

    $lba &= 0xffffff;   # negative lbas use only 24 bits 
    $m = int($lba / (CD_SECS * CD_FRAMES));
    $lba %= (CD_SECS * CD_FRAMES);
    $s = int($lba / CD_FRAMES);
    $f = int($lba % CD_FRAMES);

    return ($m, $s, $f);
}

sub EnterRecord
{
    my $this = shift @_;
    my $tracks = shift @_;
    my $title = shift @_;
    my $artistname = shift @_;
    my $diskid = shift @_;
    my $toc = shift @_;
    my ($artistid, $albumid);
    my ($sql, $sql2);
    my ($i, $ar, $al, $d, @ids, $num, $t);

    if (!defined $artistname || $artistname eq '')
    {
        $artistname = "Unknown";
    }

    $ar = Artist->new($this->{DBH});
    $ar->SetName($artistname);
    $ar->SetSortName($artistname);
    $artistid = $ar->Insert();
    if (not defined $artistid)
    {
        return 0;
    }

    @ids = $ar->GetAlbumsByName($title);
    for(;defined($al = shift @ids);)
    {
        $num = $al->GetTrackCount();
        if (!defined $num || $num < 0)
        {
            undef $al;
            last;
        }
        last if ($num == $tracks);
    }

    if (!defined $al)
    {
        $al = Album->new($this->{DBH});
        $al->SetArtist($artistid);
        $al->SetName($title);
        $albumid = $al->Insert();
        if (!defined $albumid)
        {
            return 0;
        }
    }
    for($i = 0; $i < $tracks; $i++)
    {
        $title = shift @_;
        $title = "Unknown" if $title eq '';

        $t = Track->new($this->{DBH});
        $t->SetName($title);
        $t->SetSequence($i + 1);
        if (!defined $t->Insert($al, $ar))
        {
            print STDERR "Inserting track $title ($artistid, $albumid) failed.\n";
        }
    }
    $d = Diskid->new($this->{DBH});
    $d->Insert($diskid, $al->GetId(), $toc);

    return $albumid;
}

sub Lookup
{
    my ($this, $diskid, $toc) = @_;
    my ($i, $first, $last, $leadout, @cddb_toc);
    my ($m, $s, $f, $cddb, @cd_data);
    my ($genre, $cddb_id, $title, $details, $artist);

    $cddb = CDDBmb->new(Host  => 'www.freedb.org',
                      Port  => 888,
                      Login => "mrstinky")
      or return 0;

    my @toc = split / /, $toc;
    $first = shift @toc;
    $last = shift @toc;
    $leadout = shift @toc;

    for($i = $first; $i <= $last; $i++)
    {
        ($m, $s, $f) = _lba_to_msf(shift @toc);
        push @cddb_toc, "$i $m $s $f"; 
    }
    ($m, $s, $f) = _lba_to_msf($leadout);
    push @cddb_toc, "999 $m $s $f"; 

    @cd_data = $cddb->calculate_id(@cddb_toc);
    my @discs = $cddb->get_discs($cd_data[0], $cd_data[3], $cd_data[4]);
    foreach my $disc (@discs) 
    {
        ($genre, $cddb_id, $title) = @$disc;
        #print STDERR "$cd_data[0]: $genre $cddb_id $title\n";
        last;
    }

    #print STDERR "Disk $cd_data[0] not found\n" if (!defined $genre);
    return if (!defined $genre);
    $details = $cddb->get_disc_details($genre, $cddb_id);
    return if (!defined $details);

    if ($title =~ /^(.*) \/ (.*)$/)
    {
       $artist = $1;
       $title = $2;
    }

    return $this->EnterRecord($last, 
                              $title,
                              $artist,
                              $diskid,
                              $toc,
                              @{$details->{ttitles}});
}

package cherryEpg::Parser::RtvSloJSON;
use 5.010;
use utf8;
use Moo;
use strictures 2;
use JSON::XS;
use File::Slurp;
use Time::Piece;
use Time::Seconds;

extends 'cherryEpg::Parser';

our $VERSION = '0.26';

sub BUILD {
    my ( $self, $arg ) = @_;

    $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
    my ( $self, $option ) = @_;
    my $report = $self->{report};

    # filename =  dir/2014-03-02.json
    if ( $self->{source} !~ m|(\d{4})-(\d{2})-(\d{2})| ) {
        $self->error("Unknown date format in filename");
        return $report;
    }

    my $year  = $1;
    my $month = $2;
    my $day   = $3;

    my $content = read_file( $self->{source} );

    if ( !$content ) {
        $self->error("File empty");
        return $report;
    }

    my $json = JSON::XS->new->utf8->decode($content);

    if ( !$json ) {
        $self->error("Content not in JSON format");
        return $report;
    }

    foreach my $x ( @{ $json->{response} } ) {
        my @fields;

        # skip blocks
        next if exists $x->{flags}{is_block} && $x->{flags}{is_block} == 1;

        my $event;
        my @subTitles;

        if ( defined $x->{broadcast}{title} && $x->{broadcast}{title} ne "" ) {
            $event->{title} = $x->{broadcast}{title};
            push( @subTitles, $x->{broadcast}{eptitle} ) if defined $x->{broadcast}{eptitle} && $x->{broadcast}{eptitle} ne "";
        } elsif ( defined $x->{broadcast}{eptitle} && $x->{broadcast}{eptitle} ne "" ) {
            $event->{title} = $x->{broadcast}{eptitle};
        } elsif ( defined $x->{broadcast}{slottitle} && $x->{broadcast}{slottitle} ne "" ) {
            $event->{title} = $x->{broadcast}{slottitle};
        }
        if ( defined $x->{broadcast}{subtitle} && $x->{broadcast}{subtitle} ne "" ) {
            push( @subTitles, $x->{broadcast}{subtitle} );
        }

        push( @subTitles, "ponovitev" )               if $x->{flags}{is_repeat};
        $event->{subtitle} = join( ', ', @subTitles ) if scalar(@subTitles) > 0;

        if ( exists $x->{flags}{withparents} ) {
            my $flag = $x->{flags}{withparents};

            # Broadcast is not suitable for kids and youth up to age 15.
            if ( $flag == 2 ) {
                $event->{parental} = 13;
            }

            # Broadcast is not suitable for kids and youth up to age 12.
            elsif ( $flag == 3 ) {
                $event->{parental} = 10;
            }

            # For adults only.
            elsif ( $flag == 4 ) {
                $event->{parental} = 15;
            }
        } ## end if ( exists $x->{flags...})

        $event->{synopsis} = $x->{napovednik} || "";

        $event->{id} = $x->{id};

        $event->{duration} = $x->{duration};

        if ( $x->{ura} !~ /(\d+):(\d+)/ ) {
            $self->error( "Unknown time format [", $x->{ura}, "]" );
            return $report;
        } else {
            my $hour = $1;
            my $min  = $2;
            my $t    = localtime->strptime( "$year-$month-$day $hour:$min", "%Y-%m-%d %H:%M" );
            $t += ONE_DAY if $t->hour < 6;
            $event->{start} = $t->epoch;
        } ## end else [ if ( $x->{ura} !~ /(\d+):(\d+)/)]

        #$event->{time} = localtime( $event->{start} );

        $self->smartCorrect($event);

        push( @{ $report->{eventList} }, $event );
    } ## end foreach my $x ( @{ $json->{...}})

    return $report;
} ## end sub parse

=head3 smartCorrect( )

Fix some stupid failures.

=cut

sub smartCorrect {
    my ( $self, $event ) = @_;

    if ( !defined $event->{synopsis} ) {
        delete $event->{synopsis};
    }

    return if !$event->{title};

    if (   $event->{title} eq "Dnevnik"
        && $event->{synopsis} =~ /^Z ogledom DNEVNIKA/ ) {
        $event->{synopsis} = "Prerez dnevnega dogajanja v Sloveniji in po svetu";
    }

    if (   $event->{title} eq "Prvi dnevnik"
        && $event->{synopsis} =~ /^V Prvem dnevniku/ ) {
        delete $event->{synopsis};
    }

    if (   $event->{title} eq "Slovenska kronika"
        && $event->{synopsis} =~ /^Oddaja Slovenska kronika vsak delo/ ) {
        delete $event->{synopsis};
    }

    if (   $event->{title} eq "Vreme"
        && $event->{synopsis} =~ /^Vreme je na sporedu vsak/ ) {
        delete $event->{synopsis};
    }

    if (
        $event->{title} eq "Šport"
        && (   $event->{synopsis} =~ /^Osrednja dnevno/
            || $event->{synopsis} =~ /^V prvih dnevnih/ )
        ) {
        delete $event->{synopsis};
    } ## end if ( $event->{title} eq...)

    if (   $event->{title} eq "Poročila"
        && $event->{synopsis} =~ /^V Prvem dnevniku/ ) {
        delete $event->{synopsis};
    }

    if ( exists $event->{synopsis} && defined $event->{synopsis} ) {
        $event->{synopsis} =~ s/[ \n\r]+$//s;
        $event->{synopsis} =~ s/ *[\n\r]+/\n/s;
    }
} ## end sub smartCorrect

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;

__END__
{
    "response": [
        {
            "flags": {
                "is_block": 1
            },
            "ura": "05:40",
            "vsebina": "Tedenski izbor"
        },
        {
            "broadcast": {
                "episodenr": "0",
                "episodes": "",
                "eptitle": "",
                "idec": "P-1033308-000-2017-007",
                "idec_sn": "1033308",
                "origeptitle": {
                    "eng": "",
                    "hun": "",
                    "ita": "",
                    "slo": ""
                },
                "origtitle": {
                    "eng": "",
                    "hun": "",
                    "ita": "",
                    "slo": ""
                },
                "prog_synopsis": "Kultura je kratka aktualna informativna oddaja o kulturi in umetnosti, v kateri se praviloma izpostavljajo osrednji dogodki dneva. V njej najdejo prostor tudi mednarodne novice in problemske teme. V ustvarjanje oddaje so vklju\u010deni dopisniki doma in v tujini. Kulturo urejajo in vodijo redaktorice:Teja Kunst, Andreja Ko\u010dar, Meta \u010cesnik, Nina Jerman in \u0160pela Ko\u017ear.",
                "slottitle": "Informativna oddaja o kulturi",
                "subtitle": "",
                "title": "Kultura",
                "titles": {
                    "eng": "",
                    "hun": "",
                    "ita": "",
                    "slo": "Kultura"
                },
                "txreq_synopsis": "Kultura je kratka aktualna informativna oddaja o kulturi in umetnosti, v kateri se praviloma izpostavljajo osrednji dogodki dneva. V njej najdejo prostor tudi mednarodne novice in problemske teme. V ustvarjanje oddaje so vklju\u010deni dopisniki doma in v tujini. Kulturo urejajo in vodijo redaktorice:Teja Kunst, Andreja Ko\u010dar, Meta \u010cesnik, Nina Jerman in \u0160pela Ko\u017ear."
            },
            "duration": 300,
            "flags": {
                "archived": "1",
                "colour": "0",
                "hd": "1",
                "internet": "1",
                "internet_geo": "0",
                "is_repeat": "0",
                "production": "",
                "satkod": "0",
                "subtitles": "0",
                "withparents": "0"
            },
            "genres": {
                "fullname": "Regular \\ INFORMATIVNE VSEBINE \\ INFORMATIVNE ODDAJE \\ Informativno oddaje o kulturi in umetnosti"
            },
            "id": "810761",
            "indent": "1",
            "link": "http://www.rtvslo.si/modload.php?&c_mod=rtvoddaje&op=web&func=read&c_id=25511",
            "napovednik": "Kultura je kratka aktualna informativna oddaja o kulturi in umetnosti, v kateri se praviloma izpostavljajo osrednji dogodki dneva. V njej najdejo prostor tudi mednarodne novice in problemske teme. V ustvarjanje oddaje so vklju\u010deni dopisniki doma in v tujini. Kulturo urejajo in vodijo redaktorice:Teja Kunst, Andreja Ko\u010dar, Meta \u010cesnik, Nina Jerman in \u0160pela Ko\u017ear.",
            "participants": {
                "casting": "",
                "director": "",
                "scenarist": "",
                "translators": ""
            },
            "thumbnail": null,
            "ura": "05:40",
            "vps": "05:40",
            "vsebina": "Kultura"
        },
        {
            "broadcast": {
                "episodenr": "0",
                "episodes": "",
                "eptitle": "",
                "idec": "P-1022211-000-2017-007",
                "idec_sn": "1022211",
                "origeptitle": {
                    "eng": "",
                    "hun": "",
                    "ita": "",
                    "slo": ""
                },
                "origtitle": {
                    "eng": "",
                    "hun": "",
                    "ita": "",
                    "slo": ""
                },
                "prog_synopsis": "Odmevi vsak delavnik ob 22.00 ponudijo sve\u017ee ve\u010derne novice ter analize najpomembnej\u0161ih dogodkov dneva. Ozadja dogodkov in pojavov, prikrite podrobnosti in nove plati vznemirljivih zgodb predstavljajo novinarji in izbrani gosti, ki jih izpra\u0161ajo voditelji oddaje ali pa se soo\u010dijo med seboj. V studiu damo besedo obema, oziroma toliko stranem, da si na\u0161i gledalci lahko ustvarijo \u010dim bolj celostno podobo aktualnih dogajanj. Poleg tega pa \u0161e kratek pregled dnevnih svetovnih in doma\u010dih novic, ki ste jih morda zamudili ali presli\u0161ali \u010dez dan.",
                "slottitle": "Dnevno - informativna oddaja",
                "subtitle": "",
                "title": "Odmevi",
                "titles": {
                    "eng": "",
                    "hun": "",
                    "ita": "",
                    "slo": "Odmevi"
                },
                "txreq_synopsis": "Odmevi vsak delavnik ob 22.00 ponudijo sve\u017ee ve\u010derne novice ter analize najpomembnej\u0161ih dogodkov dneva. Ozadja dogodkov in pojavov, prikrite podrobnosti in nove plati vznemirljivih zgodb predstavljajo novinarji in izbrani gosti, ki jih izpra\u0161ajo voditelji oddaje ali pa se soo\u010dijo med seboj. V studiu damo besedo obema, oziroma toliko stranem, da si na\u0161i gledalci lahko ustvarijo \u010dim bolj celostno podobo aktualnih dogajanj. Poleg tega pa \u0161e kratek pregled dnevnih svetovnih in doma\u010dih novic, ki ste jih morda zamudili ali presli\u0161ali \u010dez dan."
            },
            "duration": 4500,
            "flags": {
                "archived": "1",
                "colour": "0",
                "hd": "1",
                "internet": "1",
                "internet_geo": "0",
                "is_repeat": "0",
                "production": "",
                "satkod": "0",
                "subtitles": "0",
                "withparents": "0"
            },
            "genres": {
                "fullname": "Regular \\ INFORMATIVNE VSEBINE \\ DNEVNO INFORMATIVNE ODDAJE \\ Dnevniki"
            },
            "id": "810763",
            "indent": "1",
            "link": "http://www.rtvslo.si/modload.php?&c_mod=rtvoddaje&op=web&func=read&c_id=22066",
            "napovednik": "Odmevi vsak delavnik ob 22.00 ponudijo sve\u017ee ve\u010derne novice ter analize najpomembnej\u0161ih dogodkov dneva. Ozadja dogodkov in pojavov, prikrite podrobnosti in nove plati vznemirljivih zgodb predstavljajo novinarji in izbrani gosti, ki jih izpra\u0161ajo voditelji oddaje ali pa se soo\u010dijo med seboj. V studiu damo besedo obema, oziroma toliko stranem, da si na\u0161i gledalci lahko ustvarijo \u010dim bolj celostno podobo aktualnih dogajanj. Poleg tega pa \u0161e kratek pregled dnevnih svetovnih in doma\u010dih novic, ki ste jih morda zamudili ali presli\u0161ali \u010dez dan.",
            "thumbnail": null,
            "ura": "05:45",
            "vps": "05:45",
            "vsebina": "Odmevi"
        }
    ]
}

package cherryWeb;
use 5.010;
use Dancer2;
use Dancer2::Plugin::Ajax;
use Dancer2::Plugin::Auth::Extensible;
use cherryEpg;
use cherryEpg::Taster;
use cherryEpg::Scheme;
use cherryEpg::Git;
use cherryEpg::Maintainer;
use DBI qw(:sql_types);
use File::Temp qw(tempfile);
use Time::Piece;
use Sys::Hostname;
use Try::Tiny;
use Digest::MD5;
use Gzip::Faster;

my $cherry = cherryEpg->instance();

my $CHERRY_TEMPDIR = File::Temp->newdir( 'cherry_XXXXXX', TMPDIR => 1, CLEANUP => 1 );

hook before => sub {

};

hook permission_denied => sub {
    send_error( request->path, 403 );
};

hook before_template_render => sub {
    my $tokens = shift;
    my $user   = session 'logged_in_user';
    $tokens->{user}        = $user;
    $tokens->{hostname}    = hostname;
    $tokens->{description} = setting('description');
};

sub loginPageHandler {
    my $return_url = params->{return_url} // '';
    template 'login' => { hostname => hostname };
}

sub permissionDeniedPageHandler {
    return 'permissionDeniedPageHandler';
}

any '/logout' => sub {
    app->destroy_session;
    template 'goodbye';
};

hook after_login_success => sub {
    redirect request->path;
};

# the Dashboard
get '/' => require_role 'cherryweb' => sub {
    template 'dashboard' => { menu => 'dashboard' };
};

# log browser page
get '/log' => require_role 'cherryweb' => sub {
    template 'log' => { menu => 'log' };
};

# scheme
get '/scheme' => require_role 'cherryweb' => sub {
    template 'scheme' => { menu => 'scheme' };
};

# carousel manager
get '/carousel' => require_role 'cherryweb' => sub {
    template 'carousel' => { menu => 'carousel' };
};

# announcement
get '/announce' => require_role 'cherryweb' => sub {
    template 'announce' => { menu => 'announce' };
};

# show system info
get '/system' => require_role 'cherryweb' => sub {
    template 'system' => { menu => 'system' };
};

# get reference xls file
get '/scheme/reference' => require_role cherryweb => sub {
    my $file = '/var/lib/cherryepg/cherryTool/t/scheme/sample.xls';
    pass and return false unless -f $file;
    send_file( $file, system_path => 1, filename => 'sample.xls' );
};

# generate system info report for monitoring
get '/report.:format' => sub {
    my $format = param('format');

    my $taster = cherryEpg::Taster->instance();

    if ( $format eq "txt" ) {
        return send_file( \$taster->format(), content_type => 'text/plain; charset=UTF-8' );
    } elsif ( $format eq "json" ) {
        return send_as( JSON => $taster->report() );
    } else {
        return "";
    }
};

# get events for single, group or all channels in xmltv format
get '/export/:id.xml' => sub {
    my $id = param('id');

    my $cherry = cherryEpg->instance();

    my $list;

    if ( $id eq "full" ) {
        $list = $cherry->epg->listChannel();
    } elsif ( $id =~ m/^\d+$/ ) {
        $list = $cherry->epg->listChannel($id);
    } else {
        send_error( "Not allowed", 404 );
    }

    return "" unless $list;

    header( 'Content-Type'  => 'text/xml' );
    header( 'Cache-Control' => 'no-store, no-cache, must-revalidate' );
    return $cherry->epg->channelListExport( $list, $cherry->config->{core}{exportIP}, $cherry->config->{core}{lang} );
};

# download scheme by target
get '/scheme/:target' => require_role cherryweb => sub {
    my $target = param('target');

    my $scheme = cherryEpg::Scheme->new();
    my $s      = $scheme->restore($target);

    if ($s) {
        send_file( \$s->{source}{blob}, filename => $s->{source}{filename}, content_type => 'application/excel' );
    } else {
        send_error( "Sorry, requested scheme not found!", 404 );
    }
};

# download chunk by target
get '/carousel/:target' => require_role cherryweb => sub {
    my $target = param('target');


    my $player = cherryEpg::Player->new();
    my ( $a, undef, undef, undef, undef, $serialized ) = $player->load($target);

    if ($$serialized) {
        my $gzipped = gzip($$serialized);
        send_file( \$gzipped, filename => $target . '.ets.gz', content_type => 'application/octet-stream' );
    } else {
        send_error( "Sorry, requested chunk not found!", 404 );
    }
};

# run chunk through dvbsnoop and return result
get '/dump/:target' => require_role cherryweb => sub {
    my $target = param('target');

    my $player = cherryEpg::Player->new();
    my $dump   = $player->dump($target);

    send_file( $dump, filename => $target . '.txt', content_type => 'text/plain; charset=UTF-8' );
};

# from here on there are the AJAX handlers
# status
ajax '/status' => require_role cherryweb => sub {
    my $taster = cherryEpg::Taster->instance();
    my $report = $taster->report();

    # correct timestamp/uptime format display with TIMEAGO
    my $timestamp = localtime( $report->{timestamp} );
    $report->{timestamp} = $timestamp->strftime();
    my $systemStart = localtime( time - $report->{uptime} );
    $report->{systemStart} = $systemStart->datetime();

    return send_as( JSON => $report );
};

ajax '/announce' => require_role cherryweb => sub {

    my $config = params->{'config'};

    my $cherry = cherryEpg->instance();
    my $epg    = $cherry->epg;

    if ($config) {

        # update
        my $newConfig = {
            present => {
                text    => params->{'present'} // '',
                publish => params->{'present_check'} ? 1 : 0,
            },
            following => {
                text    => params->{'following'} // '',
                publish => params->{'following_check'} ? 1 : 0,
            }
        };
        if ( $epg->announcerSave($newConfig) && $cherry->sectionDelete() ) {
            return send_as(
                JSON => {
                    success  => 1,
                    announce => $newConfig
                }
            );
        } else {
            return send_as( JSON => { success => 0 } );
        }
    } else {

        # just status
        return send_as(
            JSON => {
                success  => 1,
                announce => $epg->announcerLoad()
            }
        );
    } ## end else [ if ($config) ]
};

ajax '/carousel/browse' => require_role cherryweb => sub {

    my $list = cherryEpg::Player->new()->list();

    # convert date to ISO 8601 for use with timeago
    foreach my $item ( @{$list} ) {
        $item->{timestamp} = localtime( $item->{timestamp} )->datetime;
    }

    return send_as( JSON => $list );
};

ajax '/carousel/delete' => require_role cherryweb => sub {
    my $target = params->{'target'};

    my $player = cherryEpg::Player->new();

    my $report = $player->delete($target);

    return send_as( JSON => { success => $report // 0, target => $target } );
};

ajax '/carousel/pause' => require_role cherryweb => sub {
    my $target = params->{'target'};

    my $player = cherryEpg::Player->new();

    if ( $player->stop($target) ) {
        return send_as( JSON => { success => 1, target => $target } );
    }

    return send_as( JSON => { success => 0 } );
};

ajax '/carousel/play' => require_role cherryweb => sub {
    my $target = params->{'target'};

    my $player = cherryEpg::Player->new();

    if ( $player->arm( $player->load($target) ) ) {

        my $report = $player->play($target);

        if ($report) {
            return send_as( JSON => { success => 1, target => $target } );
        }
    } ## end if ( $player->arm( $player...))

    return send_as( JSON => { success => 0 } );
};

ajax '/carousel/upload' => require_role cherryweb => sub {
    my $upload = request->upload('file');

    if ( !$upload ) {
        return send_as( JSON => { success => 0 } );
    }

    my $filename = $upload->filename;
    my $tempname = $upload->tempname;

    my $player = cherryEpg::Player->new();
    my @raw    = $player->load($tempname);
    my $report;

    # when the builder fails, we generate a simulated report
    if ( !@raw ) {
        $report = {
            error  => ["Invalid file. Please contact support."],
            source => $filename
        };
    } else {

        my $md5 = Digest::MD5::md5_hex( ${ $raw[5] } );

        my $file;
        ( undef, $file ) = tempfile( 'chunkXXXXXX', OPEN => 1, UNLINK => 0, SUFFIX => '.yaml.gz', DIR => $CHERRY_TEMPDIR );

        $upload->copy_to($file);

        # save the temporary filename
        session chunkFile => $file;

        $report           = $raw[1];
        $report->{md5}    = $md5;
        $report->{size}   = length( ${ $raw[2] } );
        $report->{error}  = [];
        $report->{source} = $filename;
    } ## end else [ if ( !@raw ) ]
    return send_as( JSON => $report );
};

ajax '/carousel/save' => require_role cherryweb => sub {
    my $md5 = params->{'md5'};

    my $file = session 'chunkFile';

    if ( -e $file ) {
        my $player       = cherryEpg::Player->new();
        my @raw          = $player->load($file);
        my $md5Reference = Digest::MD5::md5_hex( ${ $raw[5] } );

        if ( $md5 eq $md5Reference ) {
            if ( $player->copy($file) ) {
                unlink($file);
                return send_as( JSON => { success => 1 } );
            }
        } ## end if ( $md5 eq $md5Reference)
        unlink($file);
    } ## end if ( -e $file )

    return send_as( JSON => { success => 0 } );
};

ajax '/carousel/upnsave' => require_role cherryweb => sub {
    my @multi = request->upload('file');

    if ( !scalar @multi ) {
        return send_as( JSON => [ { success => 0, message => 'Upload failed' } ] );
    }

    my @report = ();
    my $player = cherryEpg::Player->new();

    foreach my $upload (@multi) {
        if ( $player->load( $upload->tempname ) and $player->copy( $upload->tempname ) ) {
            push( @report, { success => 1, message => $upload->filename . ' saved' } );
        } else {
            push( @report, { success => 0, message => $upload->filename . ' failed' } );
        }
    } ## end foreach my $upload (@multi)

    return send_as( JSON => \@report );
};

ajax '/scheme/upload' => require_role cherryweb => sub {
    my $upload = request->upload('file');

    if ( !$upload ) {
        return send_as( JSON => { errorList => ["Upload failed"] } );
    }

    my $filename = $upload->filename;
    my $tempname = $upload->tempname;

    my $scheme = cherryEpg::Scheme->new();
    $scheme->readXLS($tempname);

    my $raw = $scheme->build();

    my $report;

    # when the builder fails, we generate a simulated report
    if ( !$raw ) {
        $report = {
            errorList => ["Error parsing scheme file. Please contact support."],
            source    => $filename
        };
    } else {

        # remember "original" filename
        $scheme->{scheme}{source}{filename} = $filename;

        my $file;
        ( undef, $file ) = tempfile( 'schemeXXXXXX', OPEN => 1, UNLINK => 0, SUFFIX => '.yaml.gz', DIR => $CHERRY_TEMPDIR );

        $scheme->export($file);

        # save the temporary filename
        session schemeFile => $file;

        $report = {
            channel     => scalar @{ $raw->{channel} },
            eit         => scalar @{ $raw->{eit} },
            rule        => scalar @{ $raw->{rule} },
            source      => $filename,
            description => $raw->{source}{description} // '',
            mtime       => $raw->{source}{mtime},
            errorList   => $scheme->error
        };
    } ## end else [ if ( !$raw ) ]
    return send_as( JSON => $report );
};

ajax '/scheme/browse' => require_role cherryweb => sub {

    my $list = cherryEpg::Scheme->new()->list();

    # convert date to ISO 8601 for use with timeago
    foreach my $item ( @{$list} ) {
        $item->{timestamp} = localtime( $item->{timestamp} )->datetime;
    }

    return send_as( JSON => $list );
};

ajax '/scheme/validate' => require_role cherryweb => sub {
    my $description = params->{'description'};
    my $mtime       = params->{'mtime'};

    my $file = session 'schemeFile';

    if ( -e $file ) {
        my $scheme = cherryEpg::Scheme->new();
        if ( $scheme->Import($file) ) {
            if ( $mtime eq $scheme->{scheme}{source}{mtime} ) {
                $scheme->{scheme}{source}{description} = $description;
                $scheme->export($file);

                return send_as(
                    JSON => {
                        success     => 1,
                        description => $description
                    }
                );
            } ## end if ( $mtime eq $scheme...)
        } ## end if ( $scheme->Import($file...))
        unlink($file) if -e $file;
    } ## end if ( -e $file )
    return send_as( JSON => { success => 0 } );
};

ajax '/scheme/prepare' => require_role cherryweb => sub {
    my $target = params->{'target'};

    my $scheme = cherryEpg::Scheme->new();

    my $raw = $scheme->restore($target);

    my $report;

    if ( !$raw ) {
        $report = {
            errorList => ["Error preparing scheme file. Please contact support."],
            source    => $target
        };
    } else {

        my $file;
        ( undef, $file ) = tempfile( 'schemeXXXXXX', OPEN => 1, UNLINK => 0, SUFFIX => '.yaml.gz', DIR => $CHERRY_TEMPDIR );

        $scheme->export($file);

        # save the temporary filename
        session schemeFile => $file;

        $report = {
            channel     => scalar @{ $raw->{channel} },
            eit         => scalar @{ $raw->{eit} },
            rule        => scalar @{ $raw->{rule} },
            source      => $raw->{source}{filename},
            description => $raw->{source}{description},
            mtime       => $raw->{source}{mtime},
            errorList   => $scheme->error
        };
    } ## end else [ if ( !$raw ) ]
    return send_as( JSON => $report );
};

ajax '/scheme/action' => require_role cherryweb => sub {
    my $action = params->{action};
    my $file;
    my $scheme;
    my @report = ();
    my $cherry = cherryEpg->instance();

    if ( $action eq 'maintain' ) {

    } elsif ( $action eq 'loadScheme' ) {
        $file = session 'schemeFile';

        if ( -e $file ) {
            $scheme = cherryEpg::Scheme->new();

            # try to load and compare timestamp
            if ( !$scheme->Import($file) or params->{mtime} ne $scheme->{scheme}{source}{mtime} ) {

                # if failed
                unlink($file);
                return send_as( JSON => [ { success => 0, message => 'Loading scheme' } ] );
            } ## end if ( !$scheme->Import(...))
        } else {
            return send_as( JSON => [ { success => 0, message => 'Loading file' } ] );
        }
    } else {
        return send_as( JSON => [ { success => 0, message => 'Unknown action' } ] );
    }

    # let's continue

    my $player = cherryEpg::Player->new();

    if ( $action ne 'loadScheme' and params->{deleteCarousel} ) {
        push( @report, { success => defined $player->delete(), message => 'Delete carousel' } );
    }

    if ( $action eq 'loadScheme' && !params->{stopCarousel} ) {
        push( @report, { success => defined $player->stop('EIT'), message => 'Stop EIT in carousel' } );
    }

    if ( params->{stopCarousel} ) {
        push( @report, { success => defined $player->stop(), message => 'Stop carousel' } );
    }

    if ( $action eq 'loadScheme' and params->{resetDatabase} ) {
        push( @report, { success => defined $cherry->databaseReset(), message => 'Reset tables in database' } );
    }

    if ( params->{deleteIngest} ) {
        push( @report, { success => defined $cherry->ingestDelete(), message => 'Delete ingest directory' } );
    }

    if ( ( $action eq 'loadScheme' and !params->{deleteIngest} ) or params->{reIngest} ) {
        push( @report, { success => defined $cherry->channelReset(), message => 'Reset ingest directory' } );
    }

    if ( $action eq 'loadScheme' ) {
        my ( $success, $error ) = $scheme->push();
        $scheme->backup();
        push( @report, { success => $success, message => "Load scheme (" . scalar $error->@* . " errors)" } );
        unlink($file);
    } ## end if ( $action eq 'loadScheme')

    if ( params->{grab} || params->{ingest} ) {
        my $count = scalar @{ $cherry->channelMulti( 'all', params->{grab}, params->{ingest} ) };

        my @job;
        push( @job,    'grab' )   if params->{grab};
        push( @job,    'ingest' ) if params->{ingest};
        push( @report, { success => defined $count, message => join( '&', @job ) } );
    } ## end if ( params->{grab} ||...)

    if ( params->{build} ) {
        push( @report, { success => defined $cherry->eitMulti(), message => 'Build output EIT' } );
    }

    if ( !scalar @report ) {
        push( @report, { success => 1, message => 'Nothing to-do' } );
    }

    return send_as( JSON => \@report );
};

ajax '/scheme/delete' => require_role cherryweb => sub {
    my $target = params->{'target'};

    my $scheme = cherryEpg::Scheme->new();

    my $report = $scheme->delete($target);

    return send_as( JSON => { success => $report // 0, target => $target } );
};

# current configuration
ajax '/scheme' => require_role cherryweb => sub {
    my $scheme = cherryEpg::Scheme->new();

    my $active = shift @{ $scheme->list() };
    if ($active) {
        $active->{timestamp} = localtime( $active->{timestamp} )->strftime();
    }

    return send_as( JSON => $active );
};

# show event budget for future/past
ajax '/ebudget' => require_role cherryweb => sub {
    my $t = localtime;

    my $taster = cherryEpg::Taster->instance();
    my $result = $taster->eventBudget();

    return send_as(
        JSON => {
            status    => 3,
            timestamp => $t->strftime(),
        }
        )
        unless $result;

    # convert date to ISO 8601 for use with timeago and get overall
    # worsed status
    my $status = 0;
    foreach my $channel (@$result) {
        $status = $channel->{status} if $status < $channel->{status};
        if ( $channel->{update} ) {
            my $t = localtime( $channel->{update} );
            $channel->{update} = $t->datetime;
        } else {
            $channel->{update} = undef;
        }
    } ## end foreach my $channel (@$result)

    return send_as(
        JSON => {
            data      => $result,
            status    => $status,
            timestamp => $t->strftime(),
        }
    );
};

# return service info
ajax '/service/info' => require_role cherryweb => sub {
    my $channel_id = params->{'id'};

    my $cherry = cherryEpg->instance();

    # get info
    my $result = $cherry->epg->listChannel($channel_id)->[0];
    my $last   = $cherry->epg->listChannelLastUpdate();

    # get events
    my @list = $cherry->epg->listEvent( $channel_id, undef, undef, time() );
    splice( @list, 2 );

    # if present is missing
    if ( @list == 0 || @list > 0 && $list[0]->{start} > time() ) {

        # this is not the present event
        unshift( @list, {} );
        splice( @list, 2 );
    } ## end if ( @list == 0 || @list...)

    # if following is missing
    push( @list, {} ) if @list == 1;

    foreach my $event (@list) {
        $event->{timeSpan} = '?';
        if ( $event->{start} ) {
            $event->{timeSpan} =
                localtime( $event->{start} )->strftime("%H:%M:%S") . ' - ' . localtime( $event->{stop} )->strftime("%H:%M:%S");
        }
        $event->{title}    = '-';
        $event->{subtitle} = '-';
        foreach my $desc ( $event->{descriptors}->@* ) {
            if ( exists $desc->{event_name} ) {
                $event->{title}    = $desc->{event_name};
                $event->{subtitle} = $desc->{text} || '-';
                last;
            }
        } ## end foreach my $desc ( $event->...)
        delete $event->{descriptors};
    } ## end foreach my $event (@list)


    $result->{last}   = localtime( $last->{$channel_id}{timestamp} )->strftime();
    $result->{events} = \@list;

    return send_as( JSON => $result );
};

# show ringelspiel statistics
ajax '/carousel' => require_role cherryweb => sub {
    my $taster = cherryEpg::Taster->instance();

    return send_as( JSON => $taster->ringelspiel );
};

# browse log
ajax '/log' => require_role cherryweb => sub {
    my $draw     = params->{'draw'}     // 99;
    my $start    = params->{'start'}    // 0;
    my $limit    = params->{'length'}   // 0;
    my $category = params->{'category'} // '';
    my $level    = params->{'level'}    // 0;

    my $cherry = cherryEpg->instance();
    my $t      = localtime;

    # change the filter string to a list
    my @categoryList = split( /,/, $category );

    # grep only numbers
    @categoryList = sort grep( /\d/, @categoryList );

    my ( $total, $filtered, $listRef ) = $cherry->epg->getLogList( \@categoryList, $level, $start, $limit );

    return send_as(
        JSON => {
            draw            => $draw,
            recordsTotal    => $total    // 0,
            recordsFiltered => $filtered // 0,
            data            => ref($listRef) eq 'ARRAY' ? $listRef : [],
            timestamp       => $t->strftime()
        }
    );
};

# working with the repo
ajax '/git' => require_role cherryweb => sub {

    my $status = params->{'update'} // 0;

    my $git = cherryEpg::Git->new();

    if ( !$git ) {
        return send_as(
            JSON => {
                success => 0,
                message => "Problem with repository"
            }
        );
    } ## end if ( !$git )

    if ( $status == 0 ) {
        my $s = $git->update();

        if ( !$s->{modification} && $s->{fetch} && $s->{hook} ) {

            # no local modifications, fetch successful
            if ( $s->{originCommit} ) {

                # updates available
                return send_as(
                    JSON => {
                        success => 2,
                        message => "Udates available (" . $s->{originCommit} . ")"
                    }
                );
            } else {

                # no updates
                return send_as(
                    JSON => {
                        success => 1,
                        message => "System UpToDate"
                    }
                );
            } ## end else [ if ( $s->{originCommit...})]
        } elsif ( !$s->{fetch} ) {

            # connection to repository failed
            return send_as(
                JSON => {
                    success => 0,
                    message => "Check failed"
                }
            );
        } elsif ( !$s->{hook} ) {

            # the hook file will not trigger restart
            return send_as(
                JSON => {
                    success => 0,
                    message => "Hook not installed"
                }
            );
        } else {

            # local changes
            return send_as(
                JSON => {
                    success => 0,
                    message => "Commit your local modifications"
                }
            );
        } ## end else [ if ( !$s->{modification...})]
    } elsif ( $status == 1 ) {

        # upgrade
        if ( $git->upgrade() ) {
            return send_as(
                JSON => {
                    success => 1,
                    message => "Upgrade done!"
                }
            );
        } else {
            return send_as(
                JSON => {
                    success => 0,
                    message => "Upgrade failed!"
                }
            );
        } ## end else [ if ( $git->upgrade() )]
    } else {

        # error
        return send_as(
            JSON => {
                success => 0,
                message => "Unknown command!"
            }
        );
    } ## end else [ if ( $status == 0 ) ]
};

# working with the repo
ajax '/maintenance' => require_role cherryweb => sub {
    my $upload = request->upload('file');

    if ( !$upload ) {
        return send_as(
            JSON => {
                success => 0,
                message => "Upload failed!",
            }
        );
    } ## end if ( !$upload )

    my $tempname = $upload->tempname;

    my $mtainer = cherryEpg::Maintainer->new();

    if ( $mtainer->load($tempname) ) {
        my $success = $mtainer->apply() // 0;
        my $output  = $mtainer->output;
        my $pod     = $mtainer->pod;

        return send_as(
            JSON => {
                success => $success,
                message => "[" . $mtainer->name . "] applied",
                pod     => $pod,
                content => $output,
            }
        );
    } ## end if ( $mtainer->load($tempname...))

    return send_as(
        JSON => {
            success => 0,
            message => "Loading faile!",
        }
    );
};

# read single log entry
get '/log/:id.json' => require_role cherryweb => sub {
    my $id = params->{'id'};

    my $cherry = cherryEpg->instance();

    my $info = $cherry->epg->getLogEntry($id);

    delete $info->{source}{blob}
        if ref($info) eq 'HASH' && exists $info->{source} && ref( $info->{source} ) eq 'HASH' && exists $info->{source}{blob};

    return send_as( JSON => $info );
};

# default route
any qr{.*} => sub {
    status 'not_found';
    template '404', { path => request->path };
};

=head1 AUTHOR

This software is copyright (c) 2019-2022 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;

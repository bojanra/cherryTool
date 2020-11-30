package cherryWeb;
use 5.010;
use Dancer2;
use Dancer2::Plugin::Ajax;
use Dancer2::Plugin::Auth::Extensible;
use cherryEpg;
use cherryEpg::Taster;
use cherryEpg::Scheme;
use DBI qw(:sql_types);
use File::Temp qw(tempfile);
use Time::Piece;
use Sys::Hostname;
use Try::Tiny;

our $VERSION = '1.49';

my $cherry = cherryEpg->instance();

my $CHERRY_TEMPDIR = File::Temp->newdir( 'cherry_XXXXXX', TMPDIR => 1, CLEANUP => 1 );

hook before => sub {

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

# setup
get '/setup' => require_role 'cherryweb' => sub {
    template 'setup' => { menu => 'setup' };
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
get '/setup/reference' => require_role cherryweb => sub {
    my $file = '/var/lib/cherryepg/cherryTool/t/sample.xls';
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
    } elsif ( $id =~ /^[abcde]$/ ) {

        # the selected group
        my $groupIndex = ord($id) - 97;

        # get all channels
        $list = $cherry->epg->listChannel();

        # max group
        my $groupCount = 5;
        my $total      = scalar @$list;
        my $groupSize  = int( $total / $groupCount ) + 1;
        my $start      = $groupIndex * $groupSize;

        say "total $total  size $groupSize start $start";

        # remove from start
        my (@wanted) = $groupIndex == ( $groupCount - 1 ) ? splice( @$list, $start ) : splice( @$list, $start, $groupSize );
        $list = \@wanted;
    } else {
        send_error( "Not allowed", 404 );
    }

    return "" unless $list;

    header( 'Content-Type'  => 'text/xml' );
    header( 'Cache-Control' => 'no-store, no-cache, must-revalidate' );
    return $cherry->epg->channelListExport( $list, $cherry->config->{cherryEpg}{exportIP}, $cherry->config->{cherryEpg}{lang} );
};

# download scheme by id
get '/scheme/:filename' => require_role cherryweb => sub {
    my $filename = param('filename');

    my $cherry        = cherryEpg->instance();
    my $schemeManager = cherryEpg::Scheme->new();
    my $scheme        = $schemeManager->readYAML( $cherry->schemeStoreLoad($filename) );

    if ( exists( $scheme->{source} ) ) {
        send_file( \$scheme->{source}{blob}, filename => $scheme->{source}{filename}, content_type => 'application/excel' );
    } else {
        send_error( "Sorry, no scheme here", 404 );
    }
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

# upload new configuration
ajax '/setup/upload' => require_role cherryweb => sub {
    my $upload = request->upload('file');

    if ( !$upload ) {
        return send_as( JSON => { success => 0 } );
    }

    my $filename = $upload->filename;
    my $tempname = $upload->tempname;

    my $schemeManager = cherryEpg::Scheme->new();
    $schemeManager->readXLS($tempname);

    my $raw = $schemeManager->build();

    my $report;

    # when the builder fails, we generate a simulated report
    if ( !$raw ) {
        $report = {
            error  => ["Error parsing scheme file. Please contact support."],
            source => {
                filename => $filename
            }
        };
    } else {

        # store the "original" filename
        $schemeManager->{scheme}{source}{filename} = $filename;

        # save the scheme to temporary file
        my $cherry = cherryEpg->instance();

        my $file;
        ( undef, $file ) = tempfile( 'schemeXXXXXX', OPEN => 0, UNLINK => 0, SUFFIX => '.yaml', DIR => $CHERRY_TEMPDIR );

        $schemeManager->writeYAML($file);

        # save the temporary filename
        session schemeFile => $file;

        $report = {
            channel  => scalar @{ $raw->{channel} },
            eit      => scalar @{ $raw->{eit} },
            rule     => scalar @{ $raw->{rule} },
            filename => $filename,
            mtime    => $raw->{source}{mtime},
            error    => $schemeManager->error          # TODO what if conversion failed
        };
    } ## end else [ if ( !$raw ) ]
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

ajax '/setup/browse' => require_role cherryweb => sub {

    my $cherry = cherryEpg->instance();

    my $report = $cherry->schemeStoreList();

    # convert date to ISO 8601 for use with timeago
    foreach my $file (@$report) {
        my $t = localtime( $file->{timestamp} );
        $file->{timestamp} = $t->datetime;
    }

    return send_as( JSON => $report );
};

ajax '/setup/validate' => require_role cherryweb => sub {
    my $description = params->{'description'};
    my $mtime       = params->{'mtime'};

    my $file = session 'schemeFile';

    if ( -e $file ) {
        my $schemeManager = cherryEpg::Scheme->new();
        if ( $schemeManager->readYAML($file) ) {
            if ( $mtime eq $schemeManager->{scheme}{source}{mtime} ) {
                $schemeManager->{scheme}{source}{description} = $description;
                $schemeManager->writeYAML($file);

                return send_as(
                    JSON => {
                        success     => 1,
                        description => $description
                    }
                );
            } ## end if ( $mtime eq $schemeManager...)
        } ## end if ( $schemeManager->readYAML...)
        unlink($file) if -e $file;
    } ## end if ( -e $file )
    return send_as( JSON => { success => 0 } );
};

ajax '/setup/prepare' => require_role cherryweb => sub {
    my $filename = params->{'filename'};

    my $cherry = cherryEpg->instance();

    my $schemeManager = cherryEpg::Scheme->new();

    my $scheme = $schemeManager->readYAML( $cherry->schemeStoreLoad($filename) );

    if ($scheme) {

        my $file;
        ( undef, $file ) = tempfile( 'schemeXXXXXX', OPEN => 0, UNLINK => 0, SUFFIX => '.yaml', DIR => $CHERRY_TEMPDIR );

        $schemeManager->writeYAML($file);

        # save the temporary filename
        session schemeFile => $file;

        return send_as(
            JSON => {
                success     => 1,
                mtime       => $scheme->{source}{mtime},
                description => $scheme->{source}{description}
            }
        );
    } else {
        return send_as( JSON => { success => 0 } );
    }
};

ajax '/setup/activate' => require_role cherryweb => sub {
    my $mtime  = params->{'mtime'};
    my $play   = params->{'play'};
    my $empty  = params->{'empty'};
    my $files  = params->{'files'};
    my $import = params->{'import'};
    my $grab   = params->{'grab'};

    my $file = session 'schemeFile';

    if ( -e $file ) {
        my $schemeManager = cherryEpg::Scheme->new();
        if ( $schemeManager->readYAML($file) ) {

            my $cherry = cherryEpg->instance();

            if ( $mtime eq $schemeManager->{scheme}{source}{mtime} ) {
                my $report = {};

                if ($play) {
                    $report->{play} = $cherry->carouselClean();
                } else {
                    $report->{play} = $cherry->carouselClean('EIT');
                }

                $report->{empty} = $cherry->databaseReset() if $empty;

                if ($files) {
                    $report->{files} = $cherry->ingestDelete();
                } else {
                    $report->{files} = $cherry->channelReset();
                }

                if ($import) {
                    my ( $success, $error ) = $cherry->schemeImport( $schemeManager->{scheme} );

                    $cherry->schemeStoreSave( $schemeManager->writeYAML );
                    $report->{import} = 1;
                } ## end if ($import)

                if ($grab) {
                    $report->{grab} = scalar @{ $cherry->channelGrabIngestMulti('all') };
                }

                $cherry->eitMulti();

                unlink($file);

                return send_as( JSON => $report );
            } ## end if ( $mtime eq $schemeManager...)
        } ## end if ( $schemeManager->readYAML...)
        unlink($file);
    } ## end if ( -e $file )

    return send_as( JSON => { success => 'false' } );
};

ajax '/setup/delete' => require_role cherryweb => sub {
    my $filename = params->{'filename'};

    my $cherry = cherryEpg->instance();

    my $report = $cherry->schemeStoreDelete($filename);

    return send_as( JSON => { success => $report, filename => $filename } );
};

# current configuration
ajax '/setup' => require_role cherryweb => sub {
    my $cherry = cherryEpg->instance();

    my $activeScheme = $cherry->schemeStoreLast();

    my $report = {
        channel   => scalar @{ $activeScheme->{channel} },
        eit       => scalar @{ $activeScheme->{eit} },
        rule      => scalar @{ $activeScheme->{rule} },
        filename  => $activeScheme->{source}{filename},
        timestamp => $activeScheme->{source}{timestamp},
    };

    return send_as( JSON => $report );
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

# show ringelspiel statistics
ajax '/carousel' => require_role cherryweb => sub {
    my $taster = cherryEpg::Taster->instance();

    return send_as( JSON => $taster->ringelspiel );
};

# get tooltip channel info
ajax '/channel' => require_role cherryweb => sub {
    my $channel_id = params->{'id'};
    my $cherry     = cherryEpg->instance();
    my $result     = ${ $cherry->epg->listChannel($channel_id) }[0];

    if ( $result->{channel_id} ) {
        return send_as( JSON => $result );
    } else {
        return send_as( JSON => {} );
    }
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

# read single log entry
get '/log/:id.json' => require_role cherryweb => sub {
    my $id = params->{'id'};

    my $cherry = cherryEpg->instance();

    my $info = $cherry->epg->getLogEntry($id);

    say route_parameters->get_all();

    return send_as( JSON => $info );
};

# default route
any qr{.*} => sub {
    status 'not_found';
    template '404', { path => request->path };
};

=head1 AUTHOR

This software is copyright (c) 2019-2020 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE.txt', which is part of this source code package.

=cut

1;

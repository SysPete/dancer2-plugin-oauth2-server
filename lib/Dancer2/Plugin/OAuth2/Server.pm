package Dancer2::Plugin::OAuth2::Server;

use strict;
use warnings;
use 5.008_005;
our $VERSION = '0.01';
use Dancer2::Plugin;
use URI;
use URI::QueryParam;
use Class::Load qw(try_load_class);
use Carp;

my $server = undef;

on_plugin_import {
    my $dsl      = shift;
    my $settings = plugin_setting;
    my $authorization_route = $settings->{authorize_route}//'/oauth/authorize';
    my $access_token_route  = $settings->{access_token_route}//'/oauth/access_token';

    my $server_class = $settings->{server_class}//"Dancer2::Plugin::OAuth2::Server::Simple";
    my ($ok, $error) = try_load_class($server_class);
    if (! $ok) {
        confess "Cannot load server class $server_class: $error";
    }

    $server //= $server_class->new(
        dsl         => $dsl,
        settings    => $settings,
    );

    $dsl->app->add_route(
        method  => 'get',
        regexp  => $authorization_route,
        code    => sub { _authorization_request( $dsl, $settings, $server ) }
    );
    $dsl->app->add_route(
        method  => 'post',
        regexp  => $access_token_route,
        code    => sub { _access_token_request( $dsl, $settings, $server ) }
    );
};

register 'oauth_scopes' => sub {
    my ($dsl, $scopes, $code_ref) = plugin_args(@_);

    my $settings = plugin_setting;

    $scopes = [$scopes] unless ref $scopes eq 'ARRAY';

    return sub {
        my @res = _verify_access_token_and_scope( $dsl, $settings,$server,0, @$scopes );

        if( not $res[0] ) {
            $dsl->status( 400 );
            return $dsl->to_json( { error => $res[1] } );
        } else {
            goto $code_ref;
        }
    }
};

sub _authorization_request {
    my ($dsl, $settings, $server) = @_;
    my ( $c_id,$url,$type,$scope,$state )
        = map { $dsl->param( $_ ) // undef }
        qw/ client_id redirect_uri response_type scope state /;

    my @scopes = $scope ? split( / /,$scope ) : ();

    if (
        ! defined( $c_id )
            or ! defined( $type )
            or $type ne 'code'
    ) {
        $dsl->status( 400 );
        return $dsl->to_json(
            {
                error             => 'invalid_request',
                error_description => 'the request was missing one of: client_id, '
                . 'response_type;'
                . 'or response_type did not equal "code"',
                error_uri         => '',
            }
        );
        return;
    }

    my $uri = URI->new( $url );
    my ( $res,$error ) = $server->verify_client( $c_id, \@scopes );

    if ( $res ) {
        if ( ! $server->login_resource_owner( ) ) {
            $dsl->debug( "OAuth2::Server: Resource owner not logged in" );
            # call to $resource_owner_logged_in method should have called redirect_to
            return;
        } else {
            $dsl->debug( "OAuth2::Server: Resource owner is logged in" );
            $res = $server->confirm_by_resource_owner( $c_id, \@scopes );
            if ( ! defined $res ) {
                $dsl->debug( "OAuth2::Server: Resource owner to confirm scopes" );
                # call to $resource_owner_confirms method should have called redirect_to
                return;
            }
            elsif ( $res == 0 ) {
                $dsl->debug( "OAuth2::Server: Resource owner denied scopes" );
                $error = 'access_denied';
            }
        }
    }

    if ( $res ) {
        $dsl->debug( "OAuth2::Server: Generating auth code for $c_id" );
        my $expires_in = $settings->{auth_code_ttl} // 600;

        my $auth_code = $server->generate_token( $expires_in, $c_id, \@scopes, 'auth', $url );

        $server->store_auth_code( $auth_code,$c_id,$expires_in,$url,@scopes );

        $uri->query_param_append( code  => $auth_code );

    } elsif ( $error ) {
        $uri->query_param_append( error => $error );
    } else {
        # callback has not returned anything, assume server error
        $uri->query_param_append( error             => 'server_error' );
        $uri->query_param_append( error_description => 'call to verify_client returned unexpected value' );
    }

    $uri->query_param_append( state => $state ) if defined( $state );

    $dsl->redirect( $uri );
}

sub _access_token_request {
    my ($dsl, $settings, $server) = @_;
    my ( $client_id,$client_secret,$grant_type,$auth_code,$url,$refresh_token )
        = map { $dsl->param( $_ ) // undef }
        qw/ client_id client_secret grant_type code redirect_uri refresh_token /;
    if (
        ! defined( $grant_type )
            or ( $grant_type ne 'authorization_code' and $grant_type ne 'refresh_token' )
            or ( $grant_type eq 'authorization_code' and ! defined( $auth_code ) )
            or ( $grant_type eq 'authorization_code' and ! defined( $url ) )
    ) {
        $dsl->status( 400 );
        return $dsl->to_json(
            {
                error             => 'invalid_request',
                error_description => 'the request was missing one of: grant_type, '
                . 'client_id, client_secret, code, redirect_uri;'
                . 'or grant_type did not equal "authorization_code" '
                . 'or "refresh_token"',
                error_uri         => '',
            }
        );
        return;
    }

    my $json_response = {};
    my $status        = 400;
    my ( $client,$error,$scope,$old_refresh_token,$user_id );

    if ( $grant_type eq 'refresh_token' ) {
        ( $client,$error,$scope,$user_id ) = _verify_access_token_and_scope(
            $dsl, $settings, $server, $refresh_token
        );
        $old_refresh_token = $refresh_token;
    } else {
        ( $client,$error,$scope,$user_id ) = $server->verify_auth_code(
            $client_id,$client_secret,$auth_code,$url
        );
    }

    if ( $client ) {

        $dsl->debug( "OAuth2::Server: Generating access token for $client" );

        my $expires_in    = $settings->{access_token_ttl} // 3600;
        my $access_token  = $server->generate_token( $expires_in,$client,$scope,'access',undef,$user_id );
        my $refresh_token = $server->generate_token( undef,$client,$scope,'refresh',undef,$user_id );

        $server->store_access_token(
            $client,$auth_code,$access_token,$refresh_token,
            $expires_in,$scope,$old_refresh_token
        );

        $status = 200;
        $json_response = {
            access_token  => $access_token,
            token_type    => 'Bearer',
            expires_in    => $expires_in,
            refresh_token => $refresh_token,
        };

    } elsif ( $error ) {
        $json_response->{error} = $error;
    } else {
        # callback has not returned anything, assume server error
        $json_response = {
            error             => 'server_error',
            error_description => 'call to verify_auth_code returned unexpected value',
        };
    }

    $dsl->header( 'Cache-Control' => 'no-store' );
    $dsl->header( 'Pragma'        => 'no-cache' );

    $dsl->status( $status );
    return $dsl->to_json( $json_response );
}

sub _verify_access_token_and_scope {
    my ($dsl, $settings, $server, $refresh_token, @scopes) = @_;

    my $access_token;

    if ( ! $refresh_token ) {
        if ( my $auth_header = $dsl->app->request->header( 'Authorization' ) ) {
            my ( $auth_type,$auth_access_token ) = split( / /,$auth_header );

            if ( $auth_type ne 'Bearer' ) {
                $dsl->debug( "OAuth2::Server: Auth type is not 'Bearer'" );
                return ( 0,'invalid_request' );
            } else {
                $access_token = $auth_access_token;
            }
        } else {
            $dsl->debug( "OAuth2::Server: Authorization header missing" );
            return ( 0,'invalid_request' );
        }
    } else {
        $access_token = $refresh_token;
    }

    return $server->verify_access_token( $access_token,\@scopes,$refresh_token );
}

register_plugin;

1;
__END__

=encoding utf-8

=head1 NAME

Dancer2::Plugin::OAuth2::Server - Easier implementation of an OAuth2 Authorization Server / Resource Server with Dancer2
Port of Mojolicious implementation : https://github.com/G3S/mojolicious-plugin-oauth2-server

=head1 SYNOPSIS

  use Dancer2::Plugin::OAuth2::Server;

=head1 DESCRIPTION

Dancer2::Plugin::OAuth2::Server is a port of Mojolicious plugin for OAuth2 server

=head1 AUTHOR

Pierre Vigier E<lt>pierre.vigier@gmail.comE<gt>

=head1 COPYRIGHT

Copyright 2015- Pierre Vigier

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

=cut

package MetaCPAN::Web::Model::API;

use Moose;
extends 'Catalyst::Model';

has [qw(api api_secure)] => ( is => 'ro' );

use Encode ();
use JSON;
use HTTP::Request ();
use AnyEvent;
use HTTP::Response;
use Try::Tiny 0.09;
use MooseX::ClassAttribute;
use namespace::autoclean;

class_has client => ( is => 'ro', lazy_build => 1 );

sub _build_client {
    my $client;
    eval {
        require AnyEvent::Curl::Multi;
        $client = AnyEvent::Curl::Multi->new( max_concurrency => 5 );
    } or do {
        warn "Install AnyEvent::Curl::Multi for better performance, falling back to HTTP::Tiny";
        $client = MetaCPAN::Web::Model::API::HTTP::Win32->new;
    };
    return $client;
}

{
    no warnings 'once';
    $AnyEvent::HTTP::PERSISTENT_TIMEOUT = 0;
    $AnyEvent::HTTP::USERAGENT
        = 'Mozilla/5.0 (compatible; U; MetaCPAN-Web/1.0; '
        . '+https://github.com/CPAN-API/metacpan-web)';
}

sub cv {
    AE::cv;
}

=head2 COMPONENT

Set C<api> and C<api_secure> config parameters from the app config object.

=cut

sub COMPONENT {
    my $self = shift;
    my ( $app, $config ) = @_;
    $config = $self->merge_config_hashes(
        {   api        => $app->config->{api},
            api_secure => $app->config->{api_secure} || $app->config->{api}
        },
        $config
    );
    return $self->SUPER::COMPONENT( $app, $config );
}

sub model {
    my ( $self, $model ) = @_;
    return MetaCPAN::Web->model('API') unless $model;
    return MetaCPAN::Web->model("API::$model");
}

sub request {
    my ( $self, $path, $search, $params ) = @_;
    my ( $token, $method ) = @$params{qw(token method)};
    $path .= "?access_token=$token" if ($token);
    my $req = $self->cv;
    my $request = HTTP::Request->new(
        $method ? $method : $search ? 'POST' : 'GET',
        ( $token ? $self->api_secure : $self->api ) . $path,
        ['Content-type' => 'application/json'],
    );
    # encode_json returns an octet string
    $request->add_content(encode_json($search)) if $search;

    $self->client->request($request)->cv->cb(
        sub {
        my ($response, $stats) = shift->recv;
        my $content_type = $response->header('content-type') || '';
        my $data = $response->content;

        if ( $content_type =~ /^application\/json/ ) {
            my $json = eval { decode_json($data) };
            $req->send( $@ ? $self->raw_api_response($data) : $json );
        }
        else {
            # Response is raw data, e.g. text/plain
            $req->send( $self->raw_api_response($data) );
        }
    });
    return $req;
}

# cache these
my $encoding = Encode::find_encoding('utf-8-strict')
  or warn 'UTF-8 Encoding object not found';
my $encode_check = ( Encode::FB_CROAK | Encode::LEAVE_SRC );

# TODO: Check if it's possible for the API to return any other charset.
# Do raw files, git diffs, etc get converted? Any text that goes into ES?

sub raw_api_response {
    my ($self, $data) = @_;

    # we have to assume an encoding; doing nothing is like assuming latin1
    # we'll probably have the least number of issues if we assume utf8
    try {
      if( $data ){
        # We could detect a pod =encoding line but any perl code in that file
        # is likely ascii or UTF-8.  We could potentially check for a BOM
        # but those aren't used often and aren't likely to appear here.
        # For now just attempt to decode it as UTF-8 since that's probably
        # what people should be using. (See also #378).
          # decode so the template doesn't double-encode and return mojibake
          $data = $encoding->decode( $data, $encode_check );
      }
    }
    catch {
      warn $_[0];
    };

    return +{ raw => $data };
}

package MetaCPAN::Web::Model::API::HTTP::Win32::Handle;
use Moose;

has cv => ( is => "ro" );

__PACKAGE__->meta->make_immutable;

package MetaCPAN::Web::Model::API::HTTP::Win32;
use Moose;
use AE;
use HTTP::Tiny;

sub request {
    my ($self, $req) = @_;
    my $cv = AE::cv;
    my $res = HTTP::Tiny->new->request($req->method, $req->uri, { headers => $req->headers, content => $req->content });
    warn $res->{content};
    $cv->send(
        HTTP::Response->new(
            $res->{status},
            $res->{reason},
            HTTP::Headers->new(%{$res->{headers}}),
            $res->{content}
    ));
    return MetaCPAN::Web::Model::API::HTTP::Win32::Handle->new( cv => $cv );
}

1;

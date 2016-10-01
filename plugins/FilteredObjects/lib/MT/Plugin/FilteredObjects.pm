package MT::Plugin::FilteredObjects;

use strict;
use warnings;
use utf8;
use Storable qw(dclone);

use Class::Method::Modifiers qw(install_modifier);

use constant MULTIBLOG_KEYS => [qw(blog_ids include_blogs exclude_blogs blog_id include_websites site_ids exclude_websites)];

sub plugin {
    MT->component(__PACKAGE__ =~ m/::([^:]+)\z/);
}

sub insert_after {
    my ($tmpl, $id, $template_name) = @_;

    my $before = $tmpl->getElementById($id);
    foreach my $t ( @{ plugin()->load_tmpl($template_name)->tokens } ) {
        $tmpl->insertAfter( $t, $before );
        $before = $t;
    }
}

sub insert_after_by_name {
    my ($tmpl, $name, $template_name) = @_;

    my $before = pop @{$tmpl->getElementsByName($name)};
    foreach my $t ( @{ plugin()->load_tmpl($template_name)->tokens } ) {
        $tmpl->insertAfter( $t, $before );
        $before = $t;
    }
}

sub template_param_list_common {
    my ( $cb, $app, $param, $tmpl ) = @_;

    return unless $app->param('_type') =~ m/\A(entry|page)\z/;

    $param->{filtere_identifier_label} = plugin()->translate('Filter Identifier');
    insert_after($tmpl, 'header_include', 'list_common_header.tmpl');
    insert_after_by_name($tmpl, 'jq_js_include', 'list_common_footer.tmpl');
    insert_after($tmpl, 'filter-label',   'list_common_field.tmpl');
}

sub pre_save_filter {
    my ( $obj ) = @_;

    my $app = MT->instance;

    return 1 unless $app->can('param');

    if (my $identifier = $app->param('filtered_objects_identifier')) {

        return $obj->error(plugin()->translate('The identifier is duplicated.'))
            if MT->model('filter')->exist({
                ($obj->id ? (id => {not => $obj->id}) : ()),
                filtered_objects_identifier => $identifier,
            });

        $obj->filtered_objects_identifier($identifier);
    }

    1;
}

sub cms_init_app {
    require MT::Filter;

    install_modifier 'MT::Filter', 'around', 'save', sub {
        my $orig = shift;
        my $self = shift;

        pre_save_filter($self)
            or return 0;
        $self->$orig(@_);
    };

    install_modifier 'MT::Filter', 'around', 'to_hash', sub {
        my $orig = shift;
        my $self = shift;

        my $hash = $self->$orig(@_);

        $hash->{filtered_objects_identifier} = $self->filtered_objects_identifier;

        $hash;
    };
}

sub pack_and {
    my ($filters) = @_;

    return unless @$filters;
    return $filters->[0] if @$filters == 1;

    my $filter = MT->model('filter')->new;
    $filter->set_values({
        blog_id   => $filters->[0]->blog_id,
        object_ds => $filters->[0]->object_ds,
    });
    $filter->append_item(
        {
            type => 'pack',
            args => {
                op    => 'and',
                items => [map {
                    {
                        type => 'pack',
                        args => {
                            op => 'and',
                            items => $_->items,
                        },
                    };
                } @$filters],
            },
        }
    );
    $filter;
}

sub load_objects {
    my ($filter, $load_options, $blog_ids) = @_;
    $blog_ids ||= [$filter->blog_id];
    $filter->load_objects(%{set_blog($load_options, join(',', @$blog_ids))});
}

sub build_filter {
    my ($ctx, $load_options, $tokens, $blog_ids) = @_;

    my @filter_groups = ([]);
    while (my $token = shift @$tokens) {
        next if lc($token) eq 'and';

        if (lc($token) eq 'or') {
            unshift @filter_groups, [];
            next;
        }

        my $filter;

        if ($token eq '(') {
            my $level = 0;
            my @group = ();
            for (my $t = shift @$tokens; @$tokens && $level == 0 && $t ne ')'; $t = shift @$tokens) {
                push @group, $t;
                $level++ if $t eq '(';
                $level-- if $t eq ')';
            }

            $filter = build_filter($ctx, \@group, $blog_ids)
                or next;
        }
        else {
            $filter = MT->model('filter')->load({
                filtered_objects_identifier => $token,
            });

            return $ctx->error(plugin()->translate("Filter Not Found") . ": $token")
                unless $filter;

            push @$blog_ids, $filter->blog_id;
        }

        push @{$filter_groups[0]}, $filter;
    }

    return if @filter_groups == 1 && !@{$filter_groups[0]};

    return $filter_groups[0][0] if @filter_groups == 1 && @{$filter_groups[0]} == 1;

    my @filters = map pack_and($_), @filter_groups;

    return unless @filters;
    return $filters[0] if @filters == 1;

    @filters = map {
        my $has_db_args = 0;
        for my $item (@{$_->items}) {
            my $ds = $_->object_ds;
            my $id = $item->{type};
            my $prop = MT::ListProperty->instance( $ds, $id )
                or return $ctx->error(
                MT->translate( 'Invalid filter type [_1]:[_2]', $ds, $id ) );

            next unless $prop->has('terms');
            my $terms = $prop->terms($item->{args}, my $db_terms = {}, my $db_args = {});
            $has_db_args ||= $db_args && %$db_args;
        }

        if ($has_db_args) {
            my @ids = map { $_->id } @{load_objects($_, $load_options) || []};
            my $filter = MT->model('filter')->new;
            $filter->set_values({
                blog_id   => $_->blog_id,
                object_ds => $_->object_ds,
            });
            $filter->append_item({
                type => 'id',
                args => {
                    value  => \@ids,
                    option => 'equal',
                },
            });
            $filter;
        }
        else {
            $_;
        }
    } @filters;

    my $filter = MT->model('filter')->new;
    $filter->set_values({
        blog_id   => $filters[0]->blog_id,
        object_ds => $filters[0]->object_ds,
    });
    $filter->append_item(
        {
            type => 'pack',
            args => {
                op    => 'or',
                items => [map {
                    {
                        type => 'pack',
                        args => {
                            op => 'and',
                            items => $_->items,
                        },
                    };
                } @filters],
            },
        }
    );

    $filter;
}

sub load_list_property_custom_fields_listing {
    my ($type) = @_;

    my $cache_key = "FilteredObjects-load-list-property-cf-$type";
    return if MT->request($cache_key);

    CustomFieldsListing::Plugin::init_request(undef, MT::Plugin::FilteredObjects::PseudoApp->new(
        app  => MT->instance,
        type => $type,
    ));

    MT->request($cache_key, 1);
}

sub load_list_property {
    if (MT->component('CustomFieldsListing')) {
        load_list_property_custom_fields_listing(@_);
    }
}

sub resolve_sort_by {
    my ($ds, $sort_by) = @_;

    my $list_props = MT::ListProperty->list_properties($ds);
    for my $k (keys %$list_props) {
        my $p = $list_props->{$k};
        next unless $p->{label};
        if (eval { $p->{label}->() } eq $sort_by) {
            $sort_by = $k;
            last;
        }
    }

    $sort_by;
}

sub set_blog {
    my ($load_options, $blog, $terms, $args) = @_;

    return dclone($load_options) if $load_options->{terms};

    if ($blog && ! ref $blog) {
        my %ids = map { $_ => 1 } grep { $_ } map { int($_) } split ',', $blog;

        my @blogs = grep { $_ } map {
            scalar MT->model('blog')->load($_);
        } keys %ids;

        if (@blogs) {
            $blog = $blogs[0];
            $terms ||= {
                blog_id => [map{ $_->id } @blogs],
            };
        }
    }
    my $scope
        = !$blog         ? 'system'
        : $blog->is_blog ? 'blog'
        :                  'website';

    $terms ||= {
        ($blog ? (blog_id => [$blog->id]) : ()),
    };
    $args  ||= {};

    $terms->{status} = MT->model('entry')->RELEASE;

    dclone({
        %$load_options,
        terms    => $terms,
        args     => $args,
        scope    => $scope,
        blog     => $blog,
        blog_id  => $blog->id,
        blog_ids => $terms->{blog_id} || do {
            my @ids;

            if ($blog) {
                push @ids, $blog->id;
                if ($scope eq 'website') {
                    push @ids, map { $_->id } @{$blog->blogs};
                }
            }

            \@ids;
        },
    });
}

sub split_tokens {
    my ($tokens) = @_;
    [grep { $_ }
        map { s/\A\s*(.*?)\s*\z/$1/; $_ }
        split /(\bOR\b|\bAND\b|\(|\))/i, $tokens];
}

sub _hdlr_entries {
    my ( $ctx, $args, $cond ) = @_;
    my $ds = $ctx->stash('tag') =~ m/entries/i ? 'entry': 'page';

    load_list_property($ds);

    my $sort_by = resolve_sort_by($ds, delete $args->{sort_by} || 'authored_on');

    my $load_options = {
        sort_by    => $sort_by,
        sort_order => delete $args->{sort_order} || 'descend',
        limit      => delete $args->{limit} || '',
        offset     => delete $args->{offset} || '',
        total      => 0,
    };

    if (grep { $args->{$_} } @{MULTIBLOG_KEYS()}) {
        my ( %blog_terms, %blog_args );
        $ctx->set_blog_load_context( $args, \%blog_terms, \%blog_args )
            or return $ctx->error( $ctx->errstr );

        $load_options = set_blog($load_options, $ctx->stash('blog'), \%blog_terms, \%blog_args);

        delete $args->{$_} for @{MULTIBLOG_KEYS()};
    }

    my $tokens   = $args->{filter};
    my $blog_ids = [];
    my $filter   = build_filter($ctx, $load_options, split_tokens($tokens), $blog_ids);

    return if $ctx->errstr;
    return $ctx->error(plugin()->translate("Filter Not Found") . ": $tokens")
        unless $filter;

    my $entries = load_objects($filter, $load_options, $blog_ids) || [];

    return $ctx->error($filter->errstr)
        if $filter->errstr;

    if (! @$entries) {
        return MT::Template::Context::_hdlr_pass_tokens_else(@_);
    }

    local $ctx->{__stash}{entries} = $entries;
    local $ctx->{__stash}{blog_id} = $entries->[0]->blog_id;
    $ctx->invoke_handler($ds eq 'entry' ? 'entries': 'pages', $args, $cond);
}

sub get_filtered_objects_entries {
    my ($app, $endpoint) = @_;
    my $ds = $endpoint->{id} =~ m/entries/i ? 'entry': 'page';

    load_list_property($ds);

    my $sort_by = resolve_sort_by($ds, scalar($app->param('sortBy')) || 'authored_on');

    my $load_options = {
        sort_by    => $sort_by,
        sort_order => scalar($app->param('sortOrder')) || 'descend',
        limit      => scalar($app->param('limit')) || '',
        offset     => scalar($app->param('offset')) || '',
        total      => 0,
    };

    if (my $ids = $app->param('blogIds')) {
        my @blogs = map {
            MT->model('blog')->load($_);
        } grep { $_ } map { int($_) } split ',', $ids;

        if (@blogs) {
            $load_options = set_blog(
                $load_options,
                $blogs[0],
                {
                    blog_id => [map{ $_->id } @blogs],
                },
            );
        }
    }

    my $tokens = $app->param('filter');
    my $eh = MT::ErrorHandler->new;
    my $blog_ids = [];
    my $filter = build_filter($eh, $load_options, split_tokens($tokens), $blog_ids);

    return $app->error($eh->errstr, 400) if $eh->errstr;
    return $app->error(plugin()->translate("Filter Not Found") . ": $tokens", 400)
        unless $filter;

    my $count   = ($load_options->{limit} || $load_options->{offset})
        ? $filter->count_objects($load_options)
        : undef;
    my $entries = load_objects($filter, $load_options, $blog_ids) || [];

    +{
        totalResults => defined($count) ? $count : scalar(@$entries),
        items => MT::DataAPI::Resource::Type::ObjectList->new($entries),
    };
}

1;

package MT::Plugin::FilteredObjects::PseudoApp;

sub new {
    my $class = shift;
    my $hash = bless {@_}, __PACKAGE__;
    $hash;
}

sub param {
    my $self = shift;
    my ($key) = @_;
    if ($key eq 'blog_id') {
        0;
    }
    elsif ($key eq '_type') {
        $self->{type};
    }
    else {
        die $key;
    }
}

sub component     { shift->{app}->component(@_); }
sub registry      { shift->{app}->registry(@_); }
sub model         { shift->{app}->model(@_); }
sub run_callbacks { shift->{app}->run_callbacks(@_); }
sub user_cookie   { 'user_cookie' }
sub mode          { 'list' }
sub set_language  {}
sub cookies       {
    +{
        'user_cookie' => +{
            value => [
                MT->model('author')->load->name . ':',
            ],
        },
    };
}

1;

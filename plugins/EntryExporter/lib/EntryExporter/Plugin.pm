package EntryExporter::Plugin;

use strict;
use utf8;
use MT::I18N;
use File::Spec;
use File::Find;
use File::Basename;

our $plugin = MT->component( 'EntryExporter' );

sub _cb_ts_entry_list_header {
    my ( $cb, $app, $tmpl_ref ) = @_;
    my $mtml = <<'MTML';
<mt:setvarblock name="system_msg" append="1">
<__trans_section component="EntryExporter">
    <div id="msg-container">
    <mt:if name="request.entry_export_error">
        <mtapp:statusmsg
            id="entry_export_error"
            class="error"
            rebuild="">
            <__trans phrase="Export error.">
        </mtapp:statusmsg>
    </mt:if>
    </div>
</__trans_section>
</mt:setvarblock>
MTML

    $$tmpl_ref .= $mtml;
    
    1;
}

sub _list_actions {
    my ( $meth, $component ) = @_;
    my $app = MT->instance;
    my $actions = {
        ee_export => {
            label       => 'Export entries',
            mode        => 'ee_start_export',
            return_args => 1,
            args        => { dialog => 1 },
            order       => 600,
            dialog      => 1,
            condition   => sub {
                my $blog = MT->instance->app->blog;
                return $blog && $blog->is_blog ? 1 : 0;
            },
        },
    }
}

sub _hdlr_ee_start_export {
    my $app = shift;
    my $blog = $app->blog;
    
    eval { require Archive::Zip };
    if ( $@ ) {
        return $app->trans_error( 'Archive::Zip is required.' );
    }
    
    my %id_table =  map { $_ => 1 } $app->param( 'id' );
    my $all_selected = $app->param( 'all_selected' );
    $app->setup_filtered_ids;
    my @filtered_ids = $app->param( 'id' );
    my %params = (
        blog_id         => $blog->id,
        $all_selected   ? ( all_selected    => $all_selected )  : (),
        _type           => $app->param( '_type' ),
        id_table        => \%id_table,
    );
    $app->build_page('ee_start_export.tmpl', \%params);
}

sub _hdlr_ee_exporting {
    my $app = shift;
    
    my $limit = 100;
    my $blog = $app->blog;
    my $page = $app->param( 'page' ) || 1;
    my $offset = ($page - 1) * $limit;
    my $out = $app->param( 'out' ) || '';
    $out = '' if $out =~ /\W/;
    
    my %id_table =  map { $_ => 1 } $app->param( 'id' );
    my $all_selected = $app->param( 'all_selected' );
    $app->setup_filtered_ids;
    my @filtered_ids = $app->param( 'id' );
    my %terms = (
        blog_id => $blog->id,
        id      => \@filtered_ids,
    );
    my $args = { offset => $offset, limit =>  $limit, 'sort' => 'id' };
    if ( $out ) {
        my $dir = File::Spec->catdir( $app->config( 'TempDir' ), $out );
        
        my $text = '';
        my $count = 0;
        my $iter = MT->model( 'entry' )->load_iter( \%terms, { offset => $offset, limit =>  $limit, 'sort' => 'id' } );
        while ( my $entry = $iter->() ) {
            _export_entry( $dir, $entry );
            $count++;
        }
        $offset = $offset + $count;
        $page++;
    } else {
        $out = time . $app->make_magic_token;
    }
    
    my ( $start, $end );
    $start = $offset + 1;
    my @next_entries = MT->model( 'entry' )->load( \%terms, { offset => $offset, limit =>  $limit } );
    $end = $offset + scalar( @next_entries );
    
    if ( $start <= $end ) {
        my %params = (
            blog_id         => $blog->id,
            $all_selected   ? ( all_selected    => $all_selected )  : (),
            _type           => $app->param( '_type' ),
            id_table        => \%id_table,
            start           => $start,
            end             => $end,
            page            => $page,
            out             => $out
        );
        $app->build_page('ee_exporting.tmpl', \%params);
    } else {
        $app->redirect( $app->uri(
                mode => 'ee_exported',
                args => {
                    blog_id => $blog->id,
                    out     => $out
                }
            )
        );
    }
}

use File::Find;
sub _hdlr_ee_exported {
    my $app = shift;
    
    my $blog = $app->blog;
    my $out = $app->param( 'out' ) || '';
    $out = '' if $out =~ /\W/;
    
    my $dir;
    if ( $out ) {
        $dir = File::Spec->catdir( $app->config( 'TempDir' ), $out );
    }
    return return $app->error( 'Temporary directory is not found.' ) unless $dir && -d $dir;
    
    eval { require Archive::Zip };
    if ( $@ ) {
        return $app->trans_error( 'Archive::Zip is required.' );
    }
    
    my $zipfile = File::Spec->catdir( $app->config( 'TempDir' ), "$out.zip" );
    my $zip = Archive::Zip->new();
    my $code = sub {
        return unless -f $File::Find::name;
        my $file = File::Spec->abs2rel( $File::Find::name, $dir );
        $zip->addFile( File::Spec->catfile( $dir, $file ), MT::I18N::utf8_off( $file ) );
    };
    File::Find::find( $code, $dir );
    
    my $umask = oct MT->config( 'UploadUmask' );
    my $old   = umask( $umask );
    $zip->writeToFileNamed( $zipfile );
    umask( $old );
    
    _regist_tempfile( $zipfile );
    
    my %params = (
        blog_id => $blog->id,
        out => $out
    );
    $app->build_page('ee_exported.tmpl', \%params);
}

sub _hdlr_ee_download {
    my $app = shift;
    
    my $blog = $app->blog;
    my $out = $app->param( 'out' ) || '';
    $out = '' if $out =~ /\W/;
    
    require MT::Util;
    my @tl = MT::Util::offset_time_list( time, $blog );
    my $ts = sprintf '%04d%02d%02d%02d%02d%02d', $tl[5]+1900, $tl[4]+1, @tl[3,2,1,0];
    
    $app->{ no_print_body } = 1;
    $app->set_header( 'Content-Disposition' => "attachment; filename=entries-@{[ $ts ]}.zip" );
    $app->set_header( 'Pragma' => 'no-cache' );
    $app->send_http_header( 'application/zip' );
    
    my $file = File::Spec->catdir( $app->config( 'TempDir' ), "$out.zip" );
    
    open( FH, '<', $file );
    binmode FH;
    my $buf;
    while ( read FH, $buf, 1024 ) {
        $app->print( $buf, );
    }
    close FH;
    
    return;
}

sub _export_entry {
    my ( $dir, $entry ) = @_;
    my $app = MT->instance;

    my %data = _dump_object( $entry );
    
    require MT::Util::YAML;
    
    require File::Spec;
    my $entry_dir = File::Spec->catdir( $dir, "@{[ $entry->class ]}_@{[ $entry->id ]}" );
    _write_tempfile( File::Spec->catfile( $entry_dir, "entry.yaml" ), MT::Util::YAML::Dump( \%data ) );
    
    my @categories = ();
    foreach my $category ( @{ $entry->categories() } ) {
        @categories = ( @categories, $category, \$category->parent_categories() );
    }
    my %hash = (); @categories = grep { ! $hash{ $_ }++ } @categories;
    my %categories_data;
    foreach my $category ( @categories ) {
        my %category_data = _dump_object( $category );
        $categories_data{ "@{[ $category->class ]}_@{[ $category->id ]}" } = \%category_data;
    }
    _write_tempfile( File::Spec->catfile( $entry_dir, "categories.yaml" ), MT::Util::YAML::Dump( \%categories_data ) );
    
    require MT::ObjectAsset;
    my @object_assets = MT::ObjectAsset->load(
        {   object_id => $entry->id,
            blog_id   => $entry->blog_id,
            object_ds => $entry->datasource
        }
    );
    
    my $get_thumbnails;
    $get_thumbnails = sub {
        my ( $asset ) = @_;
        my @thumbnails;
        if ( $asset->can( 'has_thumbnail' ) && $asset->has_thumbnail() ) {
            @thumbnails = MT->model( 'asset' )->load(
                {   parent => $asset->id,
                    class => '*'
                }
            );
        }
        return @thumbnails;
    };
    
    my @assets = ();
    foreach my $object_asset ( @object_assets ) {
        my $asset = MT->model( 'asset' )->load( $object_asset->asset_id );
        next unless $asset;
        @assets = ( @assets, $asset,  $get_thumbnails->( $asset ) );
    }
    
    require MT::FileMgr;
    my $fmgr = $entry->blog->file_mgr || MT::FileMgr->new( 'Local' );
    my %assets_data;
    foreach my $asset ( @assets ) {
        my $blob = $fmgr->get_data( $asset->file_path, 'upload' );
        next unless $blob;
        my $basename = "@{[ $asset->id ]}.@{[ $asset->file_ext ]}";
        my $path = File::Spec->catfile( $entry_dir, 'assets', $basename );
        my %asset_data = _dump_object( $asset );
        _write_tempfile( $path, $blob );
        $assets_data{ $basename } = \%asset_data;
    }
    
    
    _write_tempfile( File::Spec->catfile( $entry_dir, "assets.yaml" ), MT::Util::YAML::Dump( \%assets_data ) );
}

sub _dump_object {
    my ( $obj ) = @_;
    
    my $type = $obj->can( 'class' ) ? $obj->class : $obj->datasource;
    my $model = MT->model( $type ) ? MT->model( $type ) : ref( $obj );
    my $column_names = $model->column_names;
    
    if ( $obj->can( 'has_meta' ) && $obj->has_meta ) {
        require CustomFields::Field;
        my @fields = CustomFields::Field->load( { blog_id => [ $obj->blog_id, 0 ], obj_type => $type } );
        for my $field ( @fields ) {
            push( @$column_names, 'field.' . $field->basename );
        }
    }
    
    my %data = ();
    foreach my $column_name ( @$column_names ) {
        $data{ $column_name } = $obj->$column_name;
    }
    if ( $obj->can( 'get_tags' ) ) {
        my @tag_names = $obj->get_tags;
        $data{ tags } = \@tag_names;
    }
    if ( $type eq 'entry' ) {
        my @placement_data = ();
        my @placements = MT->model( 'placement' )->load( { entry_id => $obj->id } );
        foreach my $placement ( @placements ) {
            my %placement_data = _dump_object( $placement );
            push @placement_data, \%placement_data;
        }
        $data{ placements } = \@placement_data;
    }
    
    return %data;
}

sub _write_tempfile {
    my ( $file, $body ) = @_;
    my $app = MT->instance;
    require MT::FileMgr;
    my $fmgr = MT::FileMgr->new( 'Local' ) or die MT::FileMgr->errstr;
    my $temp = "$file.new";
    my $umask = $app->config( 'UploadUmask' );
    my $old = umask( oct $umask );
    $fmgr->mkpath( File::Basename::dirname( $file ) );
    open ( my $fh, ">$temp" ) or die "Can't open $temp!";
    binmode ( $fh );
    print $fh $body;
    close ( $fh );
    $fmgr->rename( $temp, $file );
    umask( $old );
    _regist_tempfile( $file );
    return $fmgr->exists( $file );
}

sub _regist_tempfile {
    my ( $file ) = @_;
    require MT::Session;
    my $sess_obj = MT::Session->get_by_key(
        {   id   => File::Basename::basename( $file ),
            kind => 'TF',
            name => $file,
        } );
    $sess_obj->start( time + 60 * 60 * 6 );
    $sess_obj->save;
}

1;
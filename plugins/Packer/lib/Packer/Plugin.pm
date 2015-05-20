package Packer::Plugin;

use strict;
use utf8;
use MT::I18N;
use File::Spec;
use File::Find;
use File::Basename;
use Encode;
use File::Path;

our $plugin = MT->component( 'Packer' );

sub _cb_ts_entry_list_header {
    my ( $cb, $app, $tmpl_ref ) = @_;
    my $mtml = <<'MTML';
<mt:setvarblock name="system_msg" append="1">
<__trans_section component="Packer">
    <div id="msg-container">
    <mt:if name="request.ee_imported">
        <mtapp:statusmsg
            id="ee_imported"
            class="success"
            rebuild="">
            <__trans phrase="Export finished.">
        </mtapp:statusmsg>
    </mt:if>
    </div>
</__trans_section>
</mt:setvarblock>
MTML

    $$tmpl_ref .= $mtml;
    
    1;
}

sub _content_actions {
    my ( $meth, $component ) = @_;
    my $app = MT->instance;
    my $type = $app->param( '_type' );
    return {
        'ee_upload' => {
            class       => 'icon-create',
            mode        => 'ee_start_import',
            label       => $plugin->translate( 'Import [_1]', $plugin->translate( $type eq 'entry' ? 'entries' : 'pages' ) ),
            return_args => 1,
            args        => { dialog => 1, _type => $type },
            dialog      => 1,
            condition   => sub {
                my $app = MT->instance->app;
                my $blog = $app->blog;
                return $blog && $app->can_do( 'create_post' ) && $app->can_do( 'upload' ) ? 1 : 0;
            },
        },
    };
}

sub _list_actions {
    my ( $meth, $component ) = @_;
    my $app = MT->instance;
    my $type = $app->param( '_type' );
    my $actions = {
        ee_export => {
            label       => $plugin->translate( 'Export [_1]', $plugin->translate( $type eq 'entry' ? 'entries' : 'pages' ) ),
            mode        => 'ee_start_export',
            return_args => 1,
            args        => { dialog => 1, _type => $type },
            order       => 600,
            dialog      => 1,
            condition   => sub {
                my $blog = MT->instance->app->blog;
                my $blog = $app->blog;
                return $blog && $app->can_do( 'create_post' ) && $app->can_do( 'upload' ) ? 1 : 0;
            },
        },
    }
}

sub _hdlr_ee_start_export {
    my $app = shift;
    my $blog = $app->blog;
    my $type = $app->param( '_type' );
    return $app->trans_error( 'Invalid request' ) unless $type eq 'entry' || $type eq 'page';
    
    eval { require Archive::Zip };
    if ( $@ ) {
        return $app->trans_error( 'Archive::Zip is required.' );
    }
    
    if ( $app->param( 'all_selected' ) ) {
        $app->setup_filtered_ids;
    }
    my @ids = $app->param( 'id' );
    my %terms = (
        blog_id => $blog->id,
        id      => \@ids,
    );
    my $total_count = MT->model( $type )->count( \%terms );
    unless ( $total_count ) {
        return return $app->error( 'Object has not been selected. (Please select objects in current website / blog.)' );
    }
    
    my %params = (
        blog_id         => $blog->id,
        _type           => $type,
        ids             => \@ids,
    );
    $app->build_page('ee_start_export.tmpl', \%params);
}

sub _hdlr_ee_exporting {
    my $app = shift;
    
    my $type = $app->param( '_type' );
    return $app->trans_error( 'Invalid request' ) unless $type eq 'entry' || $type eq 'page';
    my $limit = 20;
    my $blog = $app->blog;
    my $page = $app->param( 'page' ) || 1;
    my $offset = ($page - 1) * $limit;
    my $out = $app->param( 'out' ) || '';
    $out = '' if $out =~ /\W/;
    
    my @ids = $app->param( 'id' );
    my %terms = (
        blog_id => $blog->id,
        id      => \@ids,
    );
    if ( $out ) {
        my $dir = File::Spec->catdir( $app->config( 'TempDir' ), $out );
        
        my $text = '';
        my $count = 0;
        my $iter = MT->model( $type )->load_iter( \%terms, { offset => $offset, limit =>  $limit, 'sort' => 'id' } );
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
    my @next_entries = MT->model( $type )->load( \%terms, { offset => $offset, limit =>  $limit } );
    $end = $offset + scalar( @next_entries );
    
    if ( $start <= $end ) {
        my %params = (
            blog_id         => $blog->id,
            _type           => $type,
            ids             => \@ids,
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
                    out     => $out,
                    _type   => $type
                }
            )
        );
    }
}

sub _hdlr_ee_exported {
    my $app = shift;
    
    my $blog = $app->blog;
    my $type = $app->param( '_type' );
    my $out = $app->param( 'out' ) || '';
    $out = '' if $out =~ /\W/;
    return $app->trans_error( 'Invalid request' ) unless $type eq 'entry' || $type eq 'page';
    
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
        out     => $out,
        _type    => $type,
    );
    $app->build_page('ee_exported.tmpl', \%params);
}

sub _hdlr_ee_download {
    my $app = shift;
    
    my $blog = $app->blog;
    my $out = $app->param( 'out' ) || '';
    $out = '' if $out =~ /\W/;
    my $type = $app->param( '_type' );
    return $app->trans_error( 'Invalid request' ) unless $type eq 'entry' || $type eq 'page';
    
    require MT::Util;
    my @tl = MT::Util::offset_time_list( time, $blog );
    my $ts = sprintf '%04d%02d%02d%02d%02d%02d', $tl[5]+1900, $tl[4]+1, @tl[3,2,1,0];
    
    $app->{ no_print_body } = 1;
    $app->set_header( 'Content-Disposition' => "attachment; filename=@{[ $type eq 'entry' ? 'entries' : 'pages' ]}-@{[ $ts ]}.zip" );
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

    my $type = $entry->can( 'class' ) ? $entry->class : $entry->datasource;
    my %data = _dump_object( $entry );
    
    require MT::Util::YAML;
    
    require File::Spec;
    my $entry_dir = File::Spec->catdir( $dir, "@{[ $entry->class ]}_@{[ $entry->id ]}" );
    _write_tempfile( File::Spec->catfile( $entry_dir, "$type.yaml" ), MT::Util::YAML::Dump( \%data ) );
    
    my @categories = ();
    foreach my $category ( @{ $entry->categories() } ) {
        my @parent_categories = $category->parent_categories();
        @categories = ( @categories, $category, @parent_categories );
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
        $asset_data{ file_path } =~ s!@{[ quotemeta( $asset->blog->site_path ) ]}!%r!;
        $asset_data{ url } =~ s!@{[ quotemeta( $asset->blog->site_url ) ]}!%r/!;
        _write_tempfile( $path, $blob );
        $assets_data{ $basename } = \%asset_data;
    }
    _write_tempfile( File::Spec->catfile( $entry_dir, "assets.yaml" ), MT::Util::YAML::Dump( \%assets_data ) );
    
    my %assets_map;
    foreach my $asset ( @assets ) {
        $assets_map{ $asset->id } = $asset->url;
    }
    _write_tempfile( File::Spec->catfile( $entry_dir, "assets_map.yaml" ), MT::Util::YAML::Dump( \%assets_map ) );
}

sub _dump_object {
    my ( $obj ) = @_;
    
    my $type = $obj->can( 'class' ) ? $obj->class : $obj->datasource;
    my $model = MT->model( $type ) ? MT->model( $type ) : ref( $obj );
    my $column_names = $model->column_names;
    
    if ( $obj->can( 'has_meta' ) && $obj->has_meta ) {
        eval { require CustomFields::Field };
        unless ( $@ ) {
            my @fields = MT->model( 'field' )->load( { blog_id => [ $obj->blog_id, 0 ], obj_type => $type } );
            for my $field ( @fields ) {
                push( @$column_names, 'field.' . $field->basename );
            }
        }
    }
    
    my %data = ();
    foreach my $column_name ( @$column_names ) {
        $data{ $column_name } = $obj->$column_name;
    }
    if ( $obj->can( 'get_tags' ) ) {
        my @tag_names = $obj->get_tags;
        if ( @tag_names ) {
            $data{ tags } = \@tag_names;
        } else {
            $data{ tags } = undef;
        }
    }
    if ( $type eq 'entry' || $type eq 'page' ) {
        my @placement_data = ();
        my @placements = MT->model( 'placement' )->load( { blog_id => $obj->blog_id, entry_id => $obj->id } );
        foreach my $placement ( @placements ) {
            my %placement_data = _dump_object( $placement );
            push @placement_data, \%placement_data;
        }
        $data{ placements } = \@placement_data;
        
        my @objectassets_data = ();
        my @objectassets = MT->model( 'objectasset' )->load( { blog_id => $obj->blog_id, object_ds => $obj->datasource, object_id => $obj->id } );
        foreach my $objectasset ( @objectassets ) {
            my %objectasset_data = _dump_object( $objectasset );
            push @objectassets_data, \%objectasset_data;
        }
        $data{ objectassets } = \@objectassets_data;
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
    my $sess_obj = MT->model( 'session' )->get_by_key(
        {   id   => File::Basename::basename( $file ),
            kind => 'TF',
            name => $file,
        } );
    $sess_obj->start( time + 60 * 60 * 6 );
    $sess_obj->save;
}

sub _hdlr_ee_start_import {
    my $app = shift;
    my $blog = $app->blog;
    my $type = $app->param( '_type' );
    return $app->trans_error( 'Invalid request' ) unless $type eq 'entry' || $type eq 'page';
    
    eval { require Archive::Zip };
    if ( $@ ) {
        return $app->trans_error( 'Archive::Zip is required.' );
    }
    
    my %params = (
        blog_id         => $blog->id,
        _type           => $type,
        magic_token     => $app->current_magic(),
        return_args     => $app->param( 'return_args' ),
    );
    $app->build_page('ee_start_import.tmpl', \%params);
}

sub _hdlr_ee_importing {
    my $app = shift;
    my $blog = $app->blog;
    $app->validate_magic or return $app->trans_error( 'Permission denied.' );
    my $type = $app->param( '_type' );
    return $app->trans_error( 'Invalid request' ) unless $type eq 'entry' || $type eq 'page';
    
    my $q = $app->param;
    my $override = $app->param( 'override' ) ? 1 : 0;
    if ( my $fh = $q->upload( 'file' ) ) {
        my $tmp_path = $q->tmpFileName( $fh );
        my $filename = File::Basename::basename( $fh, '.*' );
        
        my $out = time . $app->make_magic_token;
        my $dir = File::Spec->catdir( $app->config( 'TempDir' ), $out );
        
        require Archive::Zip;
        my $zip = Archive::Zip->new();
        unless ( $zip->read( $tmp_path ) == 0 ) {
            return $app->error( $plugin->translate( 'An error in the reading of the ZIP file.' ) );
        }
        my @members = $zip->members();
        foreach my $member ( @members ) {
            my $name = $member->fileName;
            $name =~ s!^[/\\]+!!;
            my $basename = File::Basename::basename( $name );
            next if ( $basename =~ /^\./ );
            my $path = File::Spec->catfile ( $dir, $name );
            $zip->extractMemberWithoutPaths( $member->fileName, $path );
        }
        my %params = (
            blog_id         => $blog->id,
            _type           => $type,
            out             => $out,
            override        => $override,
            magic_token     => $app->current_magic(),
            return_args     => $app->param( 'return_args' ),
        );
        $app->build_page('ee_importing.tmpl', \%params);
    } else {
        my $out = $app->param( 'out' ) || '';
        $out = '' if $out =~ /\W/;
        
        my $dir = File::Spec->catdir( $app->config( 'TempDir' ), $out );
        unless ( $out && -d $dir ) {
            return $app->trans_error( 'Invalid request.' );
        }
        
        opendir ( DIR, $dir );
        my @target;
        while ( defined ( my $path = readdir( DIR ) ) ) {
            next unless $path !~ /^\./;
            if ( $path =~ /^(entry|page)_\d+/ ) {
                push @target, File::Spec->catdir( $dir, $path );
            }
        }
        closedir ( DIR );
        
        my $finish = @target ? 0 : 1;
        unless ( $finish ) {
            my $count = 0;
            my $remnant = scalar @target;
            foreach my $entry_dir ( @target ) {
                _import_entry( $blog, $entry_dir, $override );
                File::Path::rmtree( $entry_dir );
                $remnant--;
                last if ( ++$count == 10 );
            }
            
            my %params = (
                blog_id         => $blog->id,
                _type           => $type,
                out             => $out,
                override        => $override,
                magic_token     => $app->current_magic(),
                return_args     => $app->param( 'return_args' ),
                remnant         => $remnant,
            );
            $app->build_page('ee_importing.tmpl', \%params);
        } else {
            rmdir $dir;
            $app->add_return_arg( ee_imported => 1 );
            $app->call_return;
        }
    }
    
}

sub _import_entry {
    my ( $blog, $entry_dir, $override ) = @_;
    my $app = MT->instance;
    my $user = $app->user;
    my %objects;
    my %categories;
    my %assets;
    my $categories_file = File::Spec->catfile( $entry_dir, 'categories.yaml' );
    if ( -f $categories_file ) {
        my $data = MT::Util::YAML::LoadFile( $categories_file );
        foreach my $key ( keys %$data ) {
            my $cat_data = $data->{ $key };
            my $old_id = $cat_data->{ id };
            delete $cat_data->{ id };
            my $class = $cat_data->{ class } eq 'folder' ? 'folder' : 'category';
            delete $cat_data->{ class };
            my $obj = MT->model( $class )->new;
            foreach my $field ( keys %$cat_data ) {
                next unless $obj->can( $field );
                $obj->$field( $cat_data->{ $field } );
            }
            $obj->blog_id( $blog->id );
            $obj->author_id( $user ? $user->id : undef );
            
            $categories{ $old_id } = $obj;
        }
        _rebuild_category_tree( $blog, \%categories );
        foreach my $old_id ( keys %categories ) {
            $objects{ "category_@{[ $old_id ]}" } = $categories{ $old_id };
        }
    }
    
    my $assets_file = File::Spec->catfile( $entry_dir, 'assets.yaml' );
    if ( -f $assets_file ) {
        my $data = MT::Util::YAML::LoadFile( $assets_file );
        my $fmgr = $blog->file_mgr || MT::FileMgr->new( 'Local' );
        foreach my $key ( keys %$data ) {
            my $asset_data = $data->{ $key };
            my $old_id = $asset_data->{ id };
            delete $asset_data->{ id };
            my $obj = MT->model( $asset_data->{ class } )->new;
            foreach my $field ( keys %$asset_data ) {
                next unless $obj->can( $field );
                my $val = $asset_data->{ $field };
                if ( $field eq 'tags' ) {
                    if ( ref( $val ) eq 'ARRAY' ) {
                        $obj->tags( @$val );
                    } else {
                        $obj->tags( undef );
                    }
                } else {
                    $obj->$field( $val );
                }
            }
            $obj->blog_id( $blog->id );
            $obj->created_by( $user ? $user->id : undef );
            $obj->modified_by( undef );
            
            my $src = File::Spec->catfile( $entry_dir, 'assets', $key );
            $fmgr->mkpath( File::Basename::dirname( $obj->file_path ) );
            $fmgr->put( $src, $obj->file_path );
            
            $assets{ $old_id } = $obj;
        }
        _rebuild_asset_tree( $blog, \%assets );
        foreach my $old_id ( keys %assets ) {
            $objects{ "asset_@{[ $old_id ]}" } = $assets{ $old_id };
        }
    }

    my $type = 'entry';
    my $entry_file = File::Spec->catfile( $entry_dir, 'entry.yaml' );
    unless ( -f $entry_file ) {
        $type = 'page';
        $entry_file = File::Spec->catfile( $entry_dir, 'page.yaml' );
    }
    if ( -f $entry_file ) {
        my $data = MT::Util::YAML::LoadFile( $entry_file );
        
        my $do_duplicate = 0;
        my $entry_basename = $data->{ basename };
        my $entry_created_on = $data->{ created_on };
        my $orig;
        my $obj = $entry_basename ? MT->model( $type )->load( { blog_id => $blog->id, basename => $entry_basename, created_on => $entry_created_on } ) : undef;
        if ( $override ) {
            if ( $obj && $obj->modified_on > $data->{ modified_on } ) {
                _log( $plugin->translate( 'The same article is the latest destination. id:[_1](src) [_2](dst) title:[_3] modified_on:[_4](src) [_5](dst)', $data->{id}, $obj->id, $obj->title, $data->{modified_on}, $obj->modified_on ), $obj->blog );
                return;
            }
            if ( $obj ) {
                $orig = $obj->clone;
            } else {
                $obj = MT->model( $type )->new;
            }
        } else {
            if ( $obj ) {
                _log( $plugin->translate( 'The same article found, create duplicate article. id:[_1](src) [_2](dst) title:[_3]', $data->{id}, $obj->id, $obj->title ), $obj->blog );
                $do_duplicate = 1;
            }
            $obj = MT->model( $type )->new;
        }
        
        my $old_id = $data->{ id };
        delete $data->{ id };
        
        my $placements_data = delete $data->{ placements };
        my $objectassets_data = delete $data->{ objectassets };
        
        my @asset_fields = ();
        my $field_class = MT->model( 'field' );
        foreach my $field ( keys %$data ) {
            my $val = $data->{ $field };
            if ( $field =~ /^\Qfield.\E(.+)$/ ) {
                my $basename = $1;
                if ( defined $field_class ) {
                    my $cf = MT->model( 'field' )->load( { basename => $basename, blog_id => [ $blog->id, 0 ], obj_type => $type } );
                    if ( $cf ) {
                        my $type = $cf->type;
                        if ( $type eq 'file' ||
                             $type eq 'audio' ||
                             $type eq 'video' ||
                             $type eq 'image' ) {
                            push @asset_fields, {
                                basename    => $basename,
                                type        => $type,
                                value       => $val,
                            };
                        } else {
                            $obj->$field( $val );
                        }
                    }
                }
            } else {
                next unless $obj->can( $field );
                if ( $field eq 'tags' ) {
                    if ( ref( $val ) eq 'ARRAY' ) {
                        $obj->tags( @$val );
                    } else {
                        $obj->tags( undef );
                    }
                } else {
                    $obj->$field( $val );
                }
            }
        }
        $obj->blog_id( $blog->id );
        $obj->author_id( $user ? $user->id : undef );
        $obj->created_by( $user ? $user->id : undef );
        $obj->modified_by( undef );
        $obj->category_id( undef );
        
        my $assets_map_file = File::Spec->catfile( $entry_dir, 'assets_map.yaml' );
        my $assets_map = MT::Util::YAML::LoadFile( $assets_map_file );
        if ( $assets_map && %$assets_map ) {
            my ( $body, $more ) = ( $obj->text, $obj->text_more );
            foreach my $old_asset_id ( keys %$assets_map ) {
                my $old_asset_url = $assets_map->{ $old_asset_id };
                my $asset = $assets{ $old_asset_id };
                next unless $asset;
                my $asset_url = $asset->url;
                $body =~ s/$old_asset_url/$asset_url/g if $body;
                $more =~ s/$old_asset_url/$asset_url/g if $more;
            }
            $obj->text( $body );
            $obj->text_more( $more );
        }
        
        if ( $do_duplicate ) {
            require MT::Util;
            $obj->basename( MT::Util::make_unique_basename( $obj ) );
            $obj->title( $app->translate( "Copy of [_1]", $obj->title ) );
        }
        
        $obj->save or die $obj->errstr;
        
        my @old_placements = MT->model( 'placement' )->load( { blog_id => $obj->blog_id, entry_id => $obj->id } );
        foreach my $placement ( @old_placements ) {
            $placement->remove;
        }
        foreach my $placement_data ( @$placements_data ) {
            delete $placement_data->{ id };
            delete $placement_data->{ blog_id };
            delete $placement_data->{ entry_id };
            my $old_category_id = delete $placement_data->{ category_id };
            my $category = $categories{ $old_category_id };
            my $placement = MT->model( 'placement' )->new;
            foreach my $field ( keys %$placement_data ) {
                next unless $placement->can( $field );
                $placement->$field( $placement_data->{ $field } );
            }
            $placement->blog_id( $obj->blog_id );
            $placement->entry_id( $obj->id );
            $placement->category_id( $category->id );
            $placement->save or die $placement->errstr;
        }
        
        my @old_objectasset = MT->model( 'objectasset' )->load(
            {
                blog_id     => $obj->blog_id,
                object_ds   => $obj->datasource,
                object_id   => $obj->id
            } );
        foreach my $objectasset ( @old_objectasset ) {
            $objectasset->remove;
        }
        foreach my $objectasset_data ( @$objectassets_data ) {
            delete $objectasset_data->{ id };
            delete $objectasset_data->{ blog_id };
            delete $objectasset_data->{ object_id };
            my $old_asset_id = delete $objectasset_data->{ asset_id };
            my $asset = $assets{ $old_asset_id };
            unless ( $asset ) {
                _log( $plugin->translate( 'Asset is not found. id:[_1](src) entry_id:[_2](src) [_3](dst) title:[_4]', $old_asset_id, $old_id, $obj->id, $obj->title ), $obj->blog );
                next;
            }
            my $objectasset = MT->model( 'objectasset' )->new;
            foreach my $field ( keys %$objectasset_data ) {
                next unless $objectasset->can( $field );
                $objectasset->$field( $objectasset_data->{ $field } );
            }
            $objectasset->blog_id( $obj->blog_id );
            $objectasset->object_id( $obj->id );
            $objectasset->asset_id( $asset->id );
            $objectasset->save or die $objectasset->errstr;
        }
        
        foreach my $field_asset_data ( @asset_fields ) {
            my $basename = $field_asset_data->{ basename };
            my $field = 'field.' . $basename;
            my $type = $field_asset_data->{ type };
            my $val = $field_asset_data->{ val };
            if ( $val && $val =~ /mt:asset-id="(\d+)"/ ) {
                my $old_asset_id = $1;
                my $asset = $assets{ $old_asset_id };
                unless ( $asset ) {
                    _log( $plugin->translate( 'Asset is not found. id:[_1](src) entry_id:[_2](src) [_3](dst) title:[_4]', $old_asset_id, $old_id, $obj->id, $obj->title ), $obj->blog );
                    next;
                }
                my $asst_id = $asset->id;
                my $url = $asset->url;
                my $label = $type eq 'image' ? MT->translate( 'View image' ) : $asset->label;
                my $new_val = qq{<form mt:asset-id="$asst_id" class="mt-enclosure mt-enclosure-@{[ $type ]}" style="display: inline;"><a href="$url">$label</a></form>};
                $obj->$field( $new_val );
            }
        }
        $obj->save or die $obj->errstr;
        
        if ( $orig ) {
            _log( $plugin->translate( 'Updated \'[_1]\' (ID:[_2]).', $obj->title, $obj->id ), $obj->blog );
        } else {
            _log( $plugin->translate( 'Imported \'[_1]\' to [_2]', $obj->title, $obj->blog->name ), $obj->blog );
        }
        
        $objects{ "${type}_@{[ $old_id ]}" } = $obj;
    }
}

sub _rebuild_category_tree {
    my ( $blog, $ref_categories ) = @_;
    foreach my $old_id ( keys %$ref_categories ) {
        my $obj = $ref_categories->{ $old_id };
        next if $obj->parent;
        _update_or_replace_category( $old_id, $ref_categories );
    }
}

sub _update_or_replace_category {
    my ( $old_id, $ref_categories ) = @_;
    my $obj = $ref_categories->{ $old_id };
    my $parent = $obj->parent ? $ref_categories->{ $obj->parent } : undef;
    my $same_obj = MT->model( $obj->class )->load(
        {
            blog_id     => $obj->blog_id,
            basename    => $obj->basename,
            parent      => $parent ? $parent->id : 0,
        }, { limit => 1 } );
    if ( $same_obj ) {
        $ref_categories->{ $old_id } = $same_obj;
        $obj = $same_obj;
    } else {
        if ( $parent ) {
            $obj->parent( $parent->id );
        } else {
            $obj->parent( 0 );
        }
        $obj->save or die $obj->errstr;
    }
    foreach my $child_old_id ( keys %$ref_categories ) {
        my $child = $ref_categories->{ $child_old_id };
        next unless $old_id ==  $child->parent;
        next if defined $child->id;
        _update_or_replace_category( $child_old_id, $ref_categories );
    }
}

sub _rebuild_asset_tree {
    my ( $blog, $ref_categories ) = @_;
    foreach my $old_id ( keys %$ref_categories ) {
        my $obj = $ref_categories->{ $old_id };
        next if $obj->parent;
        _update_or_replace_asset( $old_id, $ref_categories );
    }
}

sub _update_or_replace_asset {
    my ( $old_id, $ref_assets ) = @_;
    my $obj = $ref_assets->{ $old_id };
    my $parent = $obj->parent ? $ref_assets->{ $obj->parent } : undef;
    my $file_path = $obj->file_path;
    $file_path =~ s!@{[ quotemeta( $obj->blog->site_path ) ]}!%r!;
    my $same_obj = MT->model( 'asset' )->load(
        {
            blog_id     => $obj->blog_id,
            file_path   => $file_path,
            class       => $obj->class,
        }, { limit => 1 } );
    if ( $same_obj ) {
        $ref_assets->{ $old_id } = $same_obj;
        $obj = $same_obj;
    } else {
        if ( $parent ) {
            $obj->parent( $parent->id );
        } else {
            $obj->parent( 0 );
        }
    }
    if ( $obj->can( 'image_width' ) && $obj->can( 'image_height' ) ) {
        $obj->image_width( undef );
        $obj->image_height( undef );
    }
    $obj->save or die $obj->errstr;
    foreach my $child_old_id ( keys %$ref_assets ) {
        my $child = $ref_assets->{ $child_old_id };
        next unless $old_id ==  $child->parent;
        next if defined $child->id;
        _update_or_replace_asset( $child_old_id, $ref_assets );
    }
}

sub import_entries {
    my ( $blog, $archive_path ) = @_;
    my $app = MT->instance;
    
    eval { require Archive::Zip };
    if ( $@ ) {
        return $app->trans_error( 'Archive::Zip is required.' );
    }
    
    my $filename = File::Basename::basename( $archive_path, '.*' );
    my $out = $filename . '_' .time;
    my $dir = File::Spec->catdir( $app->config( 'TempDir' ), $out );
        
    require Archive::Zip;
    my $zip = Archive::Zip->new();
    unless ( $zip->read( $archive_path ) == 0 ) {
        return $app->error( $plugin->translate( 'An error in the reading of the ZIP file.' ) );
    }
    my @members = $zip->members();
    foreach my $member ( @members ) {
        my $name = $member->fileName;
        $name =~ s!^[/\\]+!!;
        my $basename = File::Basename::basename( $name );
        next if ( $basename =~ /^\./ );
        my $path = File::Spec->catfile ( $dir, $name );
        $zip->extractMemberWithoutPaths( $member->fileName, $path );
    }
    
    opendir ( DIR, $dir );
    my @target;
    while ( defined ( my $path = readdir( DIR ) ) ) {
        next unless $path !~ /^\./;
        if ( $path =~ /^(entry|page)_\d+/ ) {
            push @target, File::Spec->catdir( $dir, $path );
        }
    }
    closedir ( DIR );

    foreach my $entry_dir ( @target ) {
        _import_entry( $blog, $entry_dir );
        File::Path::rmtree( $entry_dir );
    }
    rmdir $dir;
    
    1;
}

sub _log {
    my ( $message, $blog ) = @_;
    my $app = MT->instance;
    require MT::Log;
    my $log = new MT::Log;
    $log->message( $message );
    if ( $ENV{REMOTE_ADDR} ) {
        $log->ip( $ENV{REMOTE_ADDR} );
    }
    if ( $blog ) {
        $log->blog_id( $blog->id );
    }
    if ( $app->can( 'user' ) && $app->user ) {
        $log->author_id( $app->user->id );
        $log->created_by( $app->user->id );
    }
    $log->level( MT::Log::INFO() );
    $log->category( 'packer' );
    $log->save;
}

1;
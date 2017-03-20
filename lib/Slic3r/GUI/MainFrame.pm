# The main frame, the parent of all.

package Slic3r::GUI::MainFrame;
use strict;
use warnings;
use utf8;

use File::Basename qw(basename dirname);
use List::Util qw(min);
use Slic3r::Geometry qw(X Y Z);
use Wx qw(:frame :bitmap :id :misc :notebook :panel :sizer :menu :dialog :filedialog
    :font :icon wxTheApp);
use Wx::Event qw(EVT_CLOSE EVT_MENU EVT_NOTEBOOK_PAGE_CHANGED);
use base 'Wx::Frame';

our $qs_last_input_file;
our $qs_last_output_file;
our $last_config;

sub new {
    my ($class, %params) = @_;
    
    my $self = $class->SUPER::new(undef, -1, 'Slic3r', wxDefaultPosition, wxDefaultSize, wxDEFAULT_FRAME_STYLE);
    if ($^O eq 'MSWin32') {
        $self->SetIcon(Wx::Icon->new($Slic3r::var->("Slic3r.ico"), wxBITMAP_TYPE_ICO));
    } else {
        $self->SetIcon(Wx::Icon->new($Slic3r::var->("Slic3r_128px.png"), wxBITMAP_TYPE_PNG));        
    }
    
    # store input params
    # If set, the "Controller" tab for the control of the printer over serial line and the serial port settings are hidden.
    $self->{no_controller} = $params{no_controller};
    $self->{loaded} = 0;
    
    # initialize tabpanel and menubar
    $self->_init_tabpanel;
    $self->_init_menubar;
    
    # set default tooltip timer in msec
    # SetAutoPop supposedly accepts long integers but some bug doesn't allow for larger values
    # (SetAutoPop is not available on GTK.)
    eval { Wx::ToolTip::SetAutoPop(32767) };
    
    # initialize status bar
    $self->{statusbar} = Slic3r::GUI::ProgressStatusBar->new($self, -1);
    $self->{statusbar}->SetStatusText("Version $Slic3r::VERSION - Remember to check for updates at http://slic3r.org/");
    $self->SetStatusBar($self->{statusbar});
    
    $self->{loaded} = 1;
    
    # initialize layout
    {
        my $sizer = Wx::BoxSizer->new(wxVERTICAL);
        $sizer->Add($self->{tabpanel}, 1, wxEXPAND);
        $sizer->SetSizeHints($self);
        $self->SetSizer($sizer);
        $self->Fit;
        $self->SetMinSize([760, 490]);
        if (defined $Slic3r::GUI::Settings->{_}{main_frame_size}) {
            my $size = [ split ',', $Slic3r::GUI::Settings->{_}{main_frame_size}, 2 ];
            $self->SetSize($size);
            
            my $display = Wx::Display->new->GetClientArea();
            my $pos = [ split ',', $Slic3r::GUI::Settings->{_}{main_frame_pos}, 2 ];
            if (($pos->[X] + $size->[X]/2) < $display->GetRight && ($pos->[Y] + $size->[Y]/2) < $display->GetBottom) {
                $self->Move($pos);
            }
            $self->Maximize(1) if $Slic3r::GUI::Settings->{_}{main_frame_maximized};
        } else {
            $self->SetSize($self->GetMinSize);
        }
        $self->Show;
        $self->Layout;
    }
    
    # declare events
    EVT_CLOSE($self, sub {
        my (undef, $event) = @_;
        
        if ($event->CanVeto) {
            my $veto = 0;
            if ($self->{controller} && $self->{controller}->printing) {
                my $confirm = Wx::MessageDialog->new($self, "You are currently printing. Do you want to stop printing and continue anyway?",
                    'Unfinished Print', wxICON_QUESTION | wxYES_NO | wxNO_DEFAULT);
                $veto = 1 if $confirm->ShowModal == wxID_YES;
            }
            if ($veto) {
                $event->Veto;
                return;
            }
        }
        
        # save window size
        $Slic3r::GUI::Settings->{_}{main_frame_pos}  = join ',', $self->GetScreenPositionXY;
        $Slic3r::GUI::Settings->{_}{main_frame_size} = join ',', $self->GetSizeWH;
        $Slic3r::GUI::Settings->{_}{main_frame_maximized} = $self->IsMaximized;
        wxTheApp->save_settings;
        
        # propagate event
        $event->Skip;
    });
    
    return $self;
}

sub _init_tabpanel {
    my ($self) = @_;
    
    $self->{tabpanel} = my $panel = Wx::Notebook->new($self, -1, wxDefaultPosition, wxDefaultSize, wxNB_TOP | wxTAB_TRAVERSAL);
    EVT_NOTEBOOK_PAGE_CHANGED($self, $self->{tabpanel}, sub {
        my $panel = $self->{tabpanel}->GetCurrentPage;
        $panel->OnActivate if $panel->can('OnActivate');
    });
    
    $panel->AddPage($self->{plater} = Slic3r::GUI::Plater->new($panel), "Plater");
    if (!$self->{no_controller}) {
        $panel->AddPage($self->{controller} = Slic3r::GUI::Controller->new($panel), "Controller");
    }
}

sub _init_menubar {
    my ($self) = @_;
    
    # File menu
    my $fileMenu = Wx::Menu->new;
    {
        $self->_append_menu_item($fileMenu, "Open STL/OBJ/AMF…\tCtrl+O", 'Open a model', sub {
            $self->{plater}->add if $self->{plater};
        }, undef, 'brick_add.png');
        $self->_append_menu_item($fileMenu, "Open 2.5D TIN mesh…", 'Import a 2.5D TIN mesh', sub {
            $self->{plater}->add_tin if $self->{plater};
        }, undef, 'map_add.png');
        $fileMenu->AppendSeparator();
        $self->_append_menu_item($fileMenu, "&Load Config…\tCtrl+L", 'Load exported configuration file', sub {
            $self->load_config_file;
        }, undef, 'plugin_add.png');
        $self->_append_menu_item($fileMenu, "&Export Config…\tCtrl+E", 'Export current configuration to file', sub {
            $self->export_config;
        }, undef, 'plugin_go.png');
        $self->_append_menu_item($fileMenu, "&Load Config Bundle…", 'Load presets from a bundle', sub {
            $self->load_configbundle;
        }, undef, 'lorry_add.png');
        $self->_append_menu_item($fileMenu, "&Export Config Bundle…", 'Export all presets to file', sub {
            $self->export_configbundle;
        }, undef, 'lorry_go.png');
        $fileMenu->AppendSeparator();
        my $repeat;
        $self->_append_menu_item($fileMenu, "Q&uick Slice…\tCtrl+U", 'Slice file', sub {
            wxTheApp->CallAfter(sub {
                $self->quick_slice;
                $repeat->Enable(defined $Slic3r::GUI::MainFrame::last_input_file);
            });
        }, undef, 'cog_go.png');
        $self->_append_menu_item($fileMenu, "Quick Slice and Save &As…\tCtrl+Alt+U", 'Slice file and save as', sub {
            wxTheApp->CallAfter(sub {
                $self->quick_slice(save_as => 1);
                $repeat->Enable(defined $Slic3r::GUI::MainFrame::last_input_file);
            });
        }, undef, 'cog_go.png');
        $repeat = $self->_append_menu_item($fileMenu, "&Repeat Last Quick Slice\tCtrl+Shift+U", 'Repeat last quick slice', sub {
            wxTheApp->CallAfter(sub {
                $self->quick_slice(reslice => 1);
            });
        }, undef, 'cog_go.png');
        $repeat->Enable(0);
        $fileMenu->AppendSeparator();
        $self->_append_menu_item($fileMenu, "Slice to SV&G…\tCtrl+G", 'Slice file to SVG', sub {
            $self->quick_slice(save_as => 1, export_svg => 1);
        }, undef, 'shape_handles.png');
        $fileMenu->AppendSeparator();
        $self->_append_menu_item($fileMenu, "Repair STL file…", 'Automatically repair an STL file', sub {
            $self->repair_stl;
        }, undef, 'wrench.png');
        $fileMenu->AppendSeparator();
        # Cmd+, is standard on OS X - what about other operating systems?
        $self->_append_menu_item($fileMenu, "Preferences…\tCtrl+,", 'Application preferences', sub {
            Slic3r::GUI::Preferences->new($self)->ShowModal;
        }, wxID_PREFERENCES);
        $fileMenu->AppendSeparator();
        $self->_append_menu_item($fileMenu, "&Quit", 'Quit Slic3r', sub {
            $self->Close(0);
        }, wxID_EXIT);
    }
    
    # Plater menu
    {
        my $plater = $self->{plater};
        
        $self->{plater_menu} = Wx::Menu->new;
        $self->_append_menu_item($self->{plater_menu}, "Export G-code...", 'Export current plate as G-code', sub {
            $plater->export_gcode;
        }, undef, 'cog_go.png');
        $self->_append_menu_item($self->{plater_menu}, "Export plate as STL...", 'Export current plate as STL', sub {
            $plater->export_stl;
        }, undef, 'brick_go.png');
        $self->_append_menu_item($self->{plater_menu}, "Export plate with modifiers as AMF...", 'Export current plate as AMF, including all modifier meshes', sub {
            $plater->export_amf;
        }, undef, 'brick_go.png');
        
        $self->{object_menu} = $self->{plater}->object_menu;
        $self->on_plater_selection_changed(0);
    }
    
    # Settings menu
    my $settingsMenu = Wx::Menu->new;
    {
        $self->_append_menu_item($settingsMenu, "P&rint Settings…\tCtrl+1", 'Show the print settings editor', sub {
            $self->{plater}->show_preset_editor('print');
        }, undef, 'cog.png');
        $self->_append_menu_item($settingsMenu, "&Filament Settings…\tCtrl+2", 'Show the filament settings editor', sub {
            $self->{plater}->show_preset_editor('filament');
        }, undef, 'spool.png');
        $self->_append_menu_item($settingsMenu, "Print&er Settings…\tCtrl+3", 'Show the printer settings editor', sub {
            $self->{plater}->show_preset_editor('printer');
        }, undef, 'printer_empty.png');
    }

    # View menu
    {
        $self->{viewMenu} = Wx::Menu->new;
        $self->_append_menu_item($self->{viewMenu}, "Iso"    , 'Iso View'    , sub { $self->select_view('iso'    ); });
        $self->_append_menu_item($self->{viewMenu}, "Top"    , 'Top View'    , sub { $self->select_view('top'    ); });
        $self->_append_menu_item($self->{viewMenu}, "Bottom" , 'Bottom View' , sub { $self->select_view('bottom' ); });
        $self->_append_menu_item($self->{viewMenu}, "Front"  , 'Front View'  , sub { $self->select_view('front'  ); });
        $self->_append_menu_item($self->{viewMenu}, "Rear"   , 'Rear View'   , sub { $self->select_view('rear'   ); });
        $self->_append_menu_item($self->{viewMenu}, "Left"   , 'Left View'   , sub { $self->select_view('left'   ); });
        $self->_append_menu_item($self->{viewMenu}, "Right"  , 'Right View'  , sub { $self->select_view('right'  ); });
        $self->{viewMenu}->AppendSeparator();
        $self->{color_toolpaths_by_role} = $self->_append_menu_item($self->{viewMenu},
            "Color Toolpaths by Role",
            'Color toolpaths according to perimeter/infill/support material',
            sub {
                $Slic3r::GUI::Settings->{_}{color_toolpaths_by} = 'role';
                wxTheApp->save_settings;
                $self->{plater}{preview3D}->reload_print;
            },
            undef, undef, wxITEM_RADIO
        );
        $self->{color_toolpaths_by_extruder} = $self->_append_menu_item($self->{viewMenu},
            "Color Toolpaths by Filament",
            'Color toolpaths using the configured extruder/filament color',
            sub {
                $Slic3r::GUI::Settings->{_}{color_toolpaths_by} = 'extruder';
                wxTheApp->save_settings;
                $self->{plater}{preview3D}->reload_print;
            },
            undef, undef, wxITEM_RADIO
        );
        if ($Slic3r::GUI::Settings->{_}{color_toolpaths_by} eq 'role') {
            $self->{color_toolpaths_by_role}->Check(1);
        } else {
            $self->{color_toolpaths_by_extruder}->Check(1);
        }
    }
    
    # Window menu
    my $windowMenu = Wx::Menu->new;
    {
        $self->_append_menu_item($windowMenu, "&Plater\tCtrl+T", 'Show the plater', sub {
            $self->select_tab(0);
        }, undef, 'application_view_tile.png');
        $self->_append_menu_item($windowMenu, "&Controller\tCtrl+Y", 'Show the printer controller', sub {
            $self->select_tab(1);
        }, undef, 'printer_empty.png') if !$self->{no_controller};
        $self->_append_menu_item($windowMenu, "DLP Projector…\tCtrl+P", 'Open projector window for DLP printing', sub {
            $self->{plater}->pause_background_process;
            Slic3r::GUI::SLAPrintOptions->new($self)->ShowModal;
            $self->{plater}->resume_background_process;
        }, undef, 'film.png');
    }
    
    # Help menu
    my $helpMenu = Wx::Menu->new;
    {
        $self->_append_menu_item($helpMenu, "&Configuration $Slic3r::GUI::ConfigWizard::wizard…", "Run Configuration $Slic3r::GUI::ConfigWizard::wizard", sub {
            $self->config_wizard;
        });
        $helpMenu->AppendSeparator();
        $self->_append_menu_item($helpMenu, "Slic3r &Website", 'Open the Slic3r website in your browser', sub {
            Wx::LaunchDefaultBrowser('http://slic3r.org/');
        });
        my $versioncheck = $self->_append_menu_item($helpMenu, "Check for &Updates...", 'Check for new Slic3r versions', sub {
            wxTheApp->check_version(1);
        });
        $versioncheck->Enable(wxTheApp->have_version_check);
        $self->_append_menu_item($helpMenu, "Slic3r &Manual", 'Open the Slic3r manual in your browser', sub {
            Wx::LaunchDefaultBrowser('http://manual.slic3r.org/');
        });
        $helpMenu->AppendSeparator();
        $self->_append_menu_item($helpMenu, "&About Slic3r", 'Show about dialog', sub {
            wxTheApp->about;
        });
    }
    
    # menubar
    # assign menubar to frame after appending items, otherwise special items
    # will not be handled correctly
    {
        my $menubar = Wx::MenuBar->new;
        $menubar->Append($fileMenu, "&File");
        $menubar->Append($self->{plater_menu}, "&Plater") if $self->{plater_menu};
        $menubar->Append($self->{object_menu}, "&Object") if $self->{object_menu};
        $menubar->Append($settingsMenu, "&Settings");
        $menubar->Append($self->{viewMenu}, "&View") if $self->{viewMenu};
        $menubar->Append($windowMenu, "&Window");
        $menubar->Append($helpMenu, "&Help");
        $self->SetMenuBar($menubar);
    }
}

sub is_loaded {
    my ($self) = @_;
    return $self->{loaded};
}

sub on_plater_selection_changed {
    my ($self, $have_selection) = @_;
    
    return if !defined $self->{object_menu};
    $self->{object_menu}->Enable($_->GetId, $have_selection)
        for $self->{object_menu}->GetMenuItems;
}

sub quick_slice {
    my $self = shift;
    my %params = @_;
    
    my $progress_dialog;
    eval {
        # validate configuration
        my $config = $self->{plater}->config;
        $config->validate;
        
        # select input file
        my $input_file;
        my $dir = $Slic3r::GUI::Settings->{recent}{skein_directory} || $Slic3r::GUI::Settings->{recent}{config_directory} || '';
        if (!$params{reslice}) {
            my $dialog = Wx::FileDialog->new($self, 'Choose a file to slice (STL/OBJ/AMF):', $dir, "", &Slic3r::GUI::MODEL_WILDCARD, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
            if ($dialog->ShowModal != wxID_OK) {
                $dialog->Destroy;
                return;
            }
            $input_file = Slic3r::decode_path($dialog->GetPaths);
            $dialog->Destroy;
            $qs_last_input_file = $input_file unless $params{export_svg};
        } else {
            if (!defined $qs_last_input_file) {
                Wx::MessageDialog->new($self, "No previously sliced file.",
                                       'Error', wxICON_ERROR | wxOK)->ShowModal();
                return;
            }
            if (! -e $qs_last_input_file) {
                Wx::MessageDialog->new($self, "Previously sliced file ($qs_last_input_file) not found.",
                                       'File Not Found', wxICON_ERROR | wxOK)->ShowModal();
                return;
            }
            $input_file = $qs_last_input_file;
        }
        my $input_file_basename = basename($input_file);
        $Slic3r::GUI::Settings->{recent}{skein_directory} = dirname($input_file);
        wxTheApp->save_settings;
        
        my $print_center;
        {
            my $bed_shape = Slic3r::Polygon->new_scale(@{$config->bed_shape});
            $print_center = Slic3r::Pointf->new_unscale(@{$bed_shape->bounding_box->center});
        }
        
        my $sprint = Slic3r::Print::Simple->new(
            print_center    => $print_center,
            status_cb       => sub {
                my ($percent, $message) = @_;
                return if &Wx::wxVERSION_STRING !~ / 2\.(8\.|9\.[2-9])/;
                $progress_dialog->Update($percent, "$message…");
            },
        );
        
        # keep model around
        my $model = Slic3r::Model->read_from_file($input_file);
        
        $sprint->apply_config($config);
        $sprint->set_model($model);
        # FIXME: populate placeholders (preset names etc.)
        
        # select output file
        my $output_file;
        if ($params{reslice}) {
            $output_file = $qs_last_output_file if defined $qs_last_output_file;
        } elsif ($params{save_as}) {
            $output_file = $sprint->output_filepath;
            $output_file =~ s/\.gcode$/.svg/i if $params{export_svg};
            my $dlg = Wx::FileDialog->new($self, 'Save ' . ($params{export_svg} ? 'SVG' : 'G-code') . ' file as:',
                wxTheApp->output_path(dirname($output_file)),
                basename($output_file), $params{export_svg} ? &Slic3r::GUI::FILE_WILDCARDS->{svg} : &Slic3r::GUI::FILE_WILDCARDS->{gcode}, wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
            if ($dlg->ShowModal != wxID_OK) {
                $dlg->Destroy;
                return;
            }
            $output_file = Slic3r::decode_path($dlg->GetPath);
            $qs_last_output_file = $output_file unless $params{export_svg};
            $Slic3r::GUI::Settings->{_}{last_output_path} = dirname($output_file);
            wxTheApp->save_settings;
            $dlg->Destroy;
        }
        
        # show processbar dialog
        $progress_dialog = Wx::ProgressDialog->new('Slicing…', "Processing $input_file_basename…", 
            100, $self, 0);
        $progress_dialog->Pulse;
        
        {
            my @warnings = ();
            local $SIG{__WARN__} = sub { push @warnings, $_[0] };
            
            $sprint->output_file($output_file);
            if ($params{export_svg}) {
                $sprint->export_svg;
            } else {
                $sprint->export_gcode;
            }
            $sprint->status_cb(undef);
            Slic3r::GUI::warning_catcher($self)->($_) for @warnings;
        }
        $progress_dialog->Destroy;
        undef $progress_dialog;
        
        my $message = "$input_file_basename was successfully sliced.";
        wxTheApp->notify($message);
        Wx::MessageDialog->new($self, $message, 'Slicing Done!', 
            wxOK | wxICON_INFORMATION)->ShowModal;
    };
    Slic3r::GUI::catch_error($self, sub { $progress_dialog->Destroy if $progress_dialog });
}

sub repair_stl {
    my $self = shift;
    
    my $input_file;
    {
        my $dir = $Slic3r::GUI::Settings->{recent}{skein_directory} || $Slic3r::GUI::Settings->{recent}{config_directory} || '';
        my $dialog = Wx::FileDialog->new($self, 'Select the STL file to repair:', $dir, "", &Slic3r::GUI::FILE_WILDCARDS->{stl}, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        if ($dialog->ShowModal != wxID_OK) {
            $dialog->Destroy;
            return;
        }
        $input_file = Slic3r::decode_path($dialog->GetPaths);
        $dialog->Destroy;
    }
    
    my $output_file = $input_file;
    {
        $output_file =~ s/\.stl$/_fixed.obj/i;
        my $dlg = Wx::FileDialog->new($self, "Save OBJ file (less prone to coordinate errors than STL) as:", dirname($output_file),
            basename($output_file), &Slic3r::GUI::FILE_WILDCARDS->{obj}, wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
        if ($dlg->ShowModal != wxID_OK) {
            $dlg->Destroy;
            return undef;
        }
        $output_file = Slic3r::decode_path($dlg->GetPath);
        $dlg->Destroy;
    }
    
    my $tmesh = Slic3r::TriangleMesh->new;
    $tmesh->ReadSTLFile(Slic3r::encode_path($input_file));
    $tmesh->repair;
    $tmesh->WriteOBJFile(Slic3r::encode_path($output_file));
    Slic3r::GUI::show_info($self, "Your file was repaired.", "Repair");
}

sub export_config {
    my $self = shift;
    
    my $config = $self->{plater}->config;
    eval {
        # validate configuration
        $config->validate;
    };
    Slic3r::GUI::catch_error($self) and return;
    
    my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
    my $filename = $last_config ? basename($last_config) : "config.ini";
    my $dlg = Wx::FileDialog->new($self, 'Save configuration as:', $dir, $filename, 
        &Slic3r::GUI::FILE_WILDCARDS->{ini}, wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
    if ($dlg->ShowModal == wxID_OK) {
        my $file = Slic3r::decode_path($dlg->GetPath);
        $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
        wxTheApp->save_settings;
        $last_config = $file;
        $config->save($file);
    }
    $dlg->Destroy;
}

sub load_config_file {
    my $self = shift;
    my ($file) = @_;
    
    if (!$file) {
        my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
        my $dlg = Wx::FileDialog->new($self, 'Select configuration to load:', $dir, "config.ini", 
                &Slic3r::GUI::FILE_WILDCARDS->{ini}, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        return unless $dlg->ShowModal == wxID_OK;
        $file = Slic3r::decode_path($dlg->GetPaths);
        $dlg->Destroy;
    }
    $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
    wxTheApp->save_settings;
    $last_config = $file;
    
    my $preset = wxTheApp->add_external_preset($file);
    $self->{plater}->load_presets;
    $self->{plater}->select_preset_by_name($preset->name, $_) for qw(print filament printer);
}

sub export_configbundle {
    my $self = shift;
    
    eval {
        # validate current configuration in case it's dirty
        $self->{plater}->config->validate;
    };
    Slic3r::GUI::catch_error($self) and return;
    
    my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
    my $filename = "Slic3r_config_bundle.ini";
    my $dlg = Wx::FileDialog->new($self, 'Save presets bundle as:', $dir, $filename, 
        &Slic3r::GUI::FILE_WILDCARDS->{ini}, wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
    if ($dlg->ShowModal == wxID_OK) {
        my $file = Slic3r::decode_path($dlg->GetPath);
        $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
        wxTheApp->save_settings;
        
        # leave default category empty to prevent the bundle from being parsed as a normal config file
        my $ini = { _ => {} };
        $ini->{settings}{$_} = $Slic3r::GUI::Settings->{_}{$_} for qw(autocenter);
        $ini->{presets} = $Slic3r::GUI::Settings->{presets};
        
        foreach my $section (qw(print filament printer)) {
            my @presets = wxTheApp->presets($section);
            foreach my $preset (@presets) {
                $ini->{"$section:" . $preset->name} = $preset->load_config->as_ini->{_};
            }
        }
        
        Slic3r::Config->write_ini($file, $ini);
    }
    $dlg->Destroy;
}

sub load_configbundle {
    my ($self, $file, $skip_no_id) = @_;
    
    if (!$file) {
        my $dir = $last_config ? dirname($last_config) : $Slic3r::GUI::Settings->{recent}{config_directory} || $Slic3r::GUI::Settings->{recent}{skein_directory} || '';
        my $dlg = Wx::FileDialog->new($self, 'Select configuration to load:', $dir, "config.ini", 
                &Slic3r::GUI::FILE_WILDCARDS->{ini}, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
        return unless $dlg->ShowModal == wxID_OK;
        $file = Slic3r::decode_path($dlg->GetPaths);
        $dlg->Destroy;
    }
    
    $Slic3r::GUI::Settings->{recent}{config_directory} = dirname($file);
    wxTheApp->save_settings;
    
    # load .ini file
    my $ini = Slic3r::Config->read_ini($file);
    
    if ($ini->{settings}) {
        $Slic3r::GUI::Settings->{_}{$_} = $ini->{settings}{$_} for keys %{$ini->{settings}};
        wxTheApp->save_settings;
    }
    if ($ini->{presets}) {
        $Slic3r::GUI::Settings->{presets} = $ini->{presets};
        wxTheApp->save_settings;
    }
    my $imported = 0;
    INI_BLOCK: foreach my $ini_category (sort keys %$ini) {
        next unless $ini_category =~ /^(print|filament|printer):(.+)$/;
        my ($section, $preset_name) = ($1, $2);
        my $config = Slic3r::Config->load_ini_hash($ini->{$ini_category});
        next if $skip_no_id && !$config->get($section . "_settings_id");
        
        {
            my @current_presets = Slic3r::GUI->presets($section);
            my %current_ids = map { $_ => 1 }
                grep $_,
                map $_->load_config->get($section . "_settings_id"),
                @current_presets;
            next INI_BLOCK if exists $current_ids{$config->get($section . "_settings_id")};
        }
        
        $config->save(sprintf "$Slic3r::GUI::datadir/%s/%s.ini", $section, $preset_name);
        Slic3r::debugf "Imported %s preset %s\n", $section, $preset_name;
        $imported++;
    }
    $self->{plater}->load_presets;
    
    return if !$imported;
    
    my $message = sprintf "%d presets successfully imported.", $imported;
    Slic3r::GUI::show_info($self, $message);
}

sub load_config {
    my ($self, $config) = @_;
    
    $self->{plater}->load_config($config);
}

sub config_wizard {
    my $self = shift;

    if (my $config = Slic3r::GUI::ConfigWizard->new($self)->run) {
        foreach my $group (qw(print filament printer)) {
            my $name = 'My Settings';
            $config->save(sprintf "$Slic3r::GUI::datadir/%s/%s.ini", $group, $name);
            $Slic3r::GUI::Settings->{presets}{$group} = "$name.ini";
            $self->{plater}->load_presets;
            $self->{plater}->select_preset_by_name($name, $group);
        }
    }
}

sub select_tab {
    my ($self, $tab) = @_;
    $self->{tabpanel}->SetSelection($tab);
}

# Set a camera direction, zoom to all objects.
sub select_view {
    my ($self, $direction) = @_;
    
    $self->{plater}->select_view($direction);
}

sub _append_menu_item {
    my ($self, $menu, $string, $description, $cb, $id, $icon, $kind) = @_;
    
    $id //= &Wx::NewId();
    my $item = $menu->Append($id, $string, $description, $kind);
    $self->_set_menu_item_icon($item, $icon);
    
    EVT_MENU($self, $id, $cb);
    return $item;
}

sub _set_menu_item_icon {
    my ($self, $menuItem, $icon) = @_;
    
    # SetBitmap was not available on OS X before Wx 0.9927
    if ($icon && $menuItem->can('SetBitmap')) {
        $menuItem->SetBitmap(Wx::Bitmap->new($Slic3r::var->($icon), wxBITMAP_TYPE_PNG));
    }
}

1;

/*****************************************************************************
 * file.c: configuration file handling
 *****************************************************************************
 * Copyright (C) 2001-2007 VLC authors and VideoLAN
 * $Id$
 *
 * Authors: Gildas Bazin <gbazin@videolan.org>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#ifdef HAVE_CONFIG_H
# include "config.h"
#endif

#include <errno.h>                                                  /* errno */
#include <assert.h>
#include <limits.h>
#include <fcntl.h>
#include <sys/stat.h>
#ifdef __APPLE__
#   include <xlocale.h>
#elif defined(HAVE_USELOCALE)
#include <locale.h>
#endif
#ifdef HAVE_UNISTD_H
# include <unistd.h>
#endif

#include <vlc_common.h>
#include "../libvlc.h"
#include <vlc_charset.h>
#include <vlc_fs.h>
#include <vlc_keys.h>
#include <vlc_modules.h>

#include "configuration.h"
#include "modules/modules.h"

static inline char *strdupnull (const char *src)
{
    return src ? strdup (src) : NULL;
}

/**
 * Get the user's configuration file
 */
static char *config_GetConfigFile( vlc_object_t *obj )
{
    char *psz_file = var_CreateGetNonEmptyString( obj, "config" );
    var_Destroy( obj, "config" );
    if( psz_file == NULL )
    {
        char *psz_dir = config_GetUserDir( VLC_CONFIG_DIR );

        if( asprintf( &psz_file, "%s" DIR_SEP CONFIG_FILE, psz_dir ) == -1 )
            psz_file = NULL;
        free( psz_dir );
    }
    return psz_file;
}

static FILE *config_OpenConfigFile( vlc_object_t *p_obj )
{
    char *psz_filename = config_GetConfigFile( p_obj );
    if( psz_filename == NULL )
        return NULL;

    msg_Dbg( p_obj, "opening config file (%s)", psz_filename );

    FILE *p_stream = vlc_fopen( psz_filename, "rt" );
    if( p_stream == NULL && errno != ENOENT )
    {
        msg_Err( p_obj, "cannot open config file (%s): %m",
                 psz_filename );

    }
#if !( defined(WIN32) || defined(__APPLE__) || defined(__OS2__) )
    else if( p_stream == NULL && errno == ENOENT )
    {
        /* This is the fallback for pre XDG Base Directory
         * Specification configs */
        char *home = config_GetUserDir(VLC_HOME_DIR);
        char *psz_old;

        if( home != NULL
         && asprintf( &psz_old, "%s/.vlc/" CONFIG_FILE,
                      home ) != -1 )
        {
            p_stream = vlc_fopen( psz_old, "rt" );
            if( p_stream )
            {
                /* Old config file found. We want to write it at the
                 * new location now. */
                msg_Info( p_obj->p_libvlc, "Found old config file at %s. "
                          "VLC will now use %s.", psz_old, psz_filename );
                char *psz_readme;
                if( asprintf(&psz_readme,"%s/.vlc/README",
                             home ) != -1 )
                {
                    FILE *p_readme = vlc_fopen( psz_readme, "wt" );
                    if( p_readme )
                    {
                        fprintf( p_readme, "The VLC media player "
                                 "configuration folder has moved to comply\n"
                                 "with the XDG Base Directory Specification "
                                 "version 0.6. Your\nconfiguration has been "
                                 "copied to the new location:\n%s\nYou can "
                                 "delete this directory and all its contents.",
                                  psz_filename);
                        fclose( p_readme );
                    }
                    free( psz_readme );
                }
                /* Remove the old configuration file so that --reset-config
                 * can work properly. Fortunately, Linux allows removing
                 * open files - with most filesystems. */
                unlink( psz_old );
            }
            free( psz_old );
        }
        free( home );
    }
#endif
    free( psz_filename );
    return p_stream;
}


static int64_t strtoi (const char *str)
{
    char *end;
    long long l;

    errno = 0;
    l = strtoll (str, &end, 0);

    if (!errno)
    {
#if (LLONG_MAX > 0x7fffffffffffffffLL)
        if (l > 0x7fffffffffffffffLL
         || l < -0x8000000000000000LL)
            errno = ERANGE;
#endif
        if (*end)
            errno = EINVAL;
    }
    return l;
}

#undef config_LoadConfigFile
/*****************************************************************************
 * config_LoadConfigFile: loads the configuration file.
 *****************************************************************************
 * This function is called to load the config options stored in the config
 * file.
 *****************************************************************************/
int config_LoadConfigFile( vlc_object_t *p_this )
{
    FILE *file;

    file = config_OpenConfigFile (p_this);
    if (file == NULL)
        return VLC_EGENERIC;

    /* Look for UTF-8 Byte Order Mark */
    char * (*convert) (const char *) = strdupnull;
    char bom[3];

    if ((fread (bom, 1, 3, file) != 3)
     || memcmp (bom, "\xEF\xBB\xBF", 3))
    {
        convert = FromLocaleDup;
        rewind (file); /* no BOM, rewind */
    }

    char *line = NULL;
    size_t bufsize;
    ssize_t linelen;

    /* Ensure consistent number formatting... */
    locale_t loc = newlocale (LC_NUMERIC_MASK, "C", NULL);
    locale_t baseloc = uselocale (loc);

    vlc_rwlock_wrlock (&config_lock);
    while ((linelen = getline (&line, &bufsize, file)) != -1)
    {
        line[linelen - 1] = '\0'; /* trim newline */

        /* Ignore comments, section and empty lines */
        if (memchr ("#[", line[0], 3) != NULL)
            continue;

        /* look for option name */
        const char *psz_option_name = line;

        char *ptr = strchr (line, '=');
        if (ptr == NULL)
            continue; /* syntax error */
        *ptr = '\0';

        module_config_t *item = config_FindConfig (p_this, psz_option_name);
        if (item == NULL)
            continue;

        const char *psz_option_value = ptr + 1;
        switch (CONFIG_CLASS(item->i_type))
        {
            case CONFIG_ITEM_BOOL:
            case CONFIG_ITEM_INTEGER:
            {
                int64_t l;

                errno = 0;
                l = strtoi (psz_option_value);
                if ((l > item->max.i) || (l < item->min.i))
                    errno = ERANGE;
                if (errno)
                    msg_Warn (p_this, "Integer value (%s) for %s: %m",
                              psz_option_value, psz_option_name);
                else
                    item->value.i = l;
                break;
            }

            case CONFIG_ITEM_FLOAT:
                if (!*psz_option_value)
                    break;                    /* ignore empty option */
                item->value.f = (float)atof (psz_option_value);
                break;

            default:
                free ((char *)item->value.psz);
                item->value.psz = convert (psz_option_value);
                break;
        }
    }
    vlc_rwlock_unlock (&config_lock);
    free (line);

    if (ferror (file))
    {
        msg_Err (p_this, "error reading configuration: %m");
        clearerr (file);
    }
    fclose (file);

    if (loc != (locale_t)0)
    {
        uselocale (baseloc);
        freelocale (loc);
    }
    return 0;
}

/*****************************************************************************
 * config_CreateDir: Create configuration directory if it doesn't exist.
 *****************************************************************************/
int config_CreateDir( vlc_object_t *p_this, const char *psz_dirname )
{
    if( !psz_dirname || !*psz_dirname ) return -1;

    if( vlc_mkdir( psz_dirname, 0700 ) == 0 )
        return 0;

    switch( errno )
    {
        case EEXIST:
            return 0;

        case ENOENT:
        {
            /* Let's try to create the parent directory */
            char psz_parent[strlen( psz_dirname ) + 1], *psz_end;
            strcpy( psz_parent, psz_dirname );

            psz_end = strrchr( psz_parent, DIR_SEP_CHAR );
            if( psz_end && psz_end != psz_parent )
            {
                *psz_end = '\0';
                if( config_CreateDir( p_this, psz_parent ) == 0 )
                {
                    if( !vlc_mkdir( psz_dirname, 0700 ) )
                        return 0;
                }
            }
        }
    }

    msg_Warn( p_this, "could not create %s: %m", psz_dirname );
    return -1;
}

static int
config_Write (FILE *file, const char *desc, const char *type,
              bool comment, const char *name, const char *fmt, ...)
{
    va_list ap;
    int ret;

    if (desc == NULL)
        desc = "?";

    if (fprintf (file, "# %s (%s)\n%s%s=", desc, vlc_gettext (type),
                 comment ? "#" : "", name) < 0)
        return -1;

    va_start (ap, fmt);
    ret = vfprintf (file, fmt, ap);
    va_end (ap);
    if (ret < 0)
        return -1;

    if (fputs ("\n\n", file) == EOF)
        return -1;
    return 0;
}


static int config_PrepareDir (vlc_object_t *obj)
{
    char *psz_configdir = config_GetUserDir (VLC_CONFIG_DIR);
    if (psz_configdir == NULL)
        return -1;

    int ret = config_CreateDir (obj, psz_configdir);
    free (psz_configdir);
    return ret;
}

/*****************************************************************************
 * config_SaveConfigFile: Save a module's config options.
 *****************************************************************************
 * It's no use to save the config options that kept their default values, so
 * we'll try to be a bit clever here.
 *
 * When we save we mustn't delete the config options of the modules that
 * haven't been loaded. So we cannot just create a new config file with the
 * config structures we've got in memory.
 * I don't really know how to deal with this nicely, so I will use a completly
 * dumb method ;-)
 * I will load the config file in memory, but skipping all the sections of the
 * modules we want to save. Then I will create a brand new file, dump the file
 * loaded in memory and then append the sections of the modules we want to
 * save.
 * Really stupid no ?
 *****************************************************************************/
static int SaveConfigFile (vlc_object_t *p_this)
{
    char *permanent = NULL, *temporary = NULL;

    if( config_PrepareDir( p_this ) )
    {
        msg_Err( p_this, "no configuration directory" );
        return -1;
    }

    /* List all available modules */
    module_t **list = module_list_get (NULL);

    char *bigbuf = NULL;
    size_t bigsize = 0;
    FILE *file = config_OpenConfigFile (p_this);
    if (file != NULL)
    {
        struct stat st;

        /* Some users make vlcrc read-only to prevent changes.
         * The atomic replacement scheme breaks this "feature",
         * so we check for read-only by hand. */
        if (fstat (fileno (file), &st)
         || !(st.st_mode & S_IWUSR))
        {
            msg_Err (p_this, "configuration file is read-only");
            goto error;
        }

        bigsize = (st.st_size < LONG_MAX) ? st.st_size : 0;
        bigbuf = malloc (bigsize + 1);
        if (bigbuf == NULL)
            goto error;

        /* backup file into memory, we only need to backup the sections we
         * won't save later on */
        char *p_index = bigbuf;
        char *line = NULL;
        size_t bufsize;
        ssize_t linelen;
        bool backup = false;

        while ((linelen = getline (&line, &bufsize, file)) != -1)
        {
            char *p_index2;

            if ((line[0] == '[') && (p_index2 = strchr(line,']')))
            {
                module_t *module;

                /* we found a new section, check if we need to do a backup */
                backup = true;
                for (int i = 0; (module = list[i]) != NULL; i++)
                {
                    const char *objname = module_get_object (module);

                    if (!strncmp (line + 1, objname, strlen (objname)))
                    {
                        backup = false; /* no, we will rewrite it! */
                        break;
                    }
                }
            }

            /* save line if requested and line is valid (doesn't begin with a
             * space, tab, or eol) */
            if (backup && !memchr ("\n\t ", line[0], 3))
            {
                memcpy (p_index, line, linelen);
                p_index += linelen;
            }
        }
        fclose (file);
        file = NULL;
        free (line);
        *p_index = '\0';
        bigsize = p_index - bigbuf;
    }

    /*
     * Save module config in file
     */
    permanent = config_GetConfigFile (p_this);
    if (!permanent)
    {
        module_list_free (list);
        goto error;
    }

    if (asprintf (&temporary, "%s.%u", permanent, getpid ()) == -1)
    {
        temporary = NULL;
        module_list_free (list);
        goto error;
    }

    /* Configuration lock must be taken before vlcrc serializer below. */
    vlc_rwlock_rdlock (&config_lock);

    /* The temporary configuration file is per-PID. Therefore SaveConfigFile()
     * should be serialized against itself within a given process. */
    static vlc_mutex_t lock = VLC_STATIC_MUTEX;
    vlc_mutex_lock (&lock);

    int fd = vlc_open (temporary, O_CREAT|O_WRONLY|O_TRUNC, S_IRUSR|S_IWUSR);
    if (fd == -1)
    {
        vlc_rwlock_unlock (&config_lock);
        vlc_mutex_unlock (&lock);
        module_list_free (list);
        goto error;
    }
    file = fdopen (fd, "wt");
    if (file == NULL)
    {
        msg_Err (p_this, "cannot create configuration file: %m");
        vlc_rwlock_unlock (&config_lock);
        close (fd);
        vlc_mutex_unlock (&lock);
        module_list_free (list);
        goto error;
    }

    fprintf( file,
        "\xEF\xBB\xBF###\n"
        "###  "PACKAGE_NAME" "PACKAGE_VERSION"\n"
        "###\n"
        "\n"
        "###\n"
        "### lines beginning with a '#' character are comments\n"
        "###\n"
        "\n" );

    /* Ensure consistent number formatting... */
    locale_t loc = newlocale (LC_NUMERIC_MASK, "C", NULL);
    locale_t baseloc = uselocale (loc);

    /* We would take the config lock here. But this would cause a lock
     * inversion with the serializer above and config_AutoSaveConfigFile().
    vlc_rwlock_rdlock (&config_lock);*/

    /* Look for the selected module, if NULL then save everything */
    module_t *p_parser;
    for (int i = 0; (p_parser = list[i]) != NULL; i++)
    {
        module_config_t *p_item, *p_end;

        if( !p_parser->i_config_items )
            continue;

        fprintf( file, "[%s]", module_get_object (p_parser) );
        if( p_parser->psz_longname )
            fprintf( file, " # %s\n\n", p_parser->psz_longname );
        else
            fprintf( file, "\n\n" );

        for( p_item = p_parser->p_config, p_end = p_item + p_parser->confsize;
             p_item < p_end;
             p_item++ )
        {
            if (!CONFIG_ITEM(p_item->i_type)   /* ignore hint */
             || p_item->b_removed              /* ignore deprecated option */
             || p_item->b_unsaveable)          /* ignore volatile option */
                continue;

            if (IsConfigIntegerType (p_item->i_type))
            {
                int64_t val = p_item->value.i;
                config_Write (file, p_item->psz_text,
                             (CONFIG_CLASS(p_item->i_type) == CONFIG_ITEM_BOOL)
                                  ? N_("boolean") : N_("integer"),
                              val == p_item->orig.i,
                              p_item->psz_name, "%"PRId64, val);
            }
            else
            if (IsConfigFloatType (p_item->i_type))
            {
                float val = p_item->value.f;
                config_Write (file, p_item->psz_text, N_("float"),
                              val == p_item->orig.f,
                              p_item->psz_name, "%f", val);
            }
            else
            {
                const char *psz_value = p_item->value.psz;
                bool modified;

                assert (IsConfigStringType (p_item->i_type));

                modified = !!strcmp (psz_value ? psz_value : "",
                                     p_item->orig.psz ? p_item->orig.psz : "");
                config_Write (file, p_item->psz_text, N_("string"),
                              !modified, p_item->psz_name, "%s",
                              psz_value ? psz_value : "");
            }
            p_item->b_dirty = false;
        }
    }
    vlc_rwlock_unlock (&config_lock);

    module_list_free (list);
    if (loc != (locale_t)0)
    {
        uselocale (baseloc);
        freelocale (loc);
    }

    /*
     * Restore old settings from the config in file
     */
    if (bigsize)
        fwrite (bigbuf, 1, bigsize, file);

    /*
     * Flush to disk and replace atomically
     */
    fflush (file); /* Flush from run-time */
    if (ferror (file))
    {
        vlc_unlink (temporary);
        vlc_mutex_unlock (&lock);
        msg_Err (p_this, "cannot write configuration file");
        clearerr (file);
        goto error;
    }
#if defined(__APPLE__) || defined(__ANDROID__)
    fsync (fd); /* Flush from OS */
#else
    fdatasync (fd); /* Flush from OS */
#endif
#if defined (WIN32) || defined (__OS2__)
    /* Windows cannot (re)move open files nor overwrite existing ones */
    fclose (file);
    vlc_unlink (permanent);
#endif
    /* Atomically replace the file... */
    if (vlc_rename (temporary, permanent))
        vlc_unlink (temporary);
    /* (...then synchronize the directory, err, TODO...) */
    /* ...and finally close the file */
    vlc_mutex_unlock (&lock);
#if !defined (WIN32) && !defined (__OS2__)
    fclose (file);
#endif

    free (temporary);
    free (permanent);
    free (bigbuf);
    return 0;

error:
    if( file )
        fclose( file );
    free (temporary);
    free (permanent);
    free (bigbuf);
    return -1;
}

int config_AutoSaveConfigFile( vlc_object_t *p_this )
{
    int ret = VLC_SUCCESS;
    bool save = false;

    assert( p_this );

    /* Check if there's anything to save */
    module_t **list = module_list_get (NULL);
    vlc_rwlock_rdlock (&config_lock);
    for (size_t i_index = 0; list[i_index] && !save; i_index++)
    {
        module_t *p_parser = list[i_index];
        module_config_t *p_item, *p_end;

        if( !p_parser->i_config_items ) continue;

        for( p_item = p_parser->p_config, p_end = p_item + p_parser->confsize;
             p_item < p_end && !save;
             p_item++ )
        {
            save = p_item->b_dirty;
        }
    }

    if (save)
        /* Note: this will get the read lock recursively. Ok. */
        ret = SaveConfigFile (p_this);
    vlc_rwlock_unlock (&config_lock);

    module_list_free (list);
    return ret;
}

#undef config_SaveConfigFile
int config_SaveConfigFile( vlc_object_t *p_this )
{
    return SaveConfigFile (p_this);
}

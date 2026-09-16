# set-omeka-php-path

Bash script for configuring the `background.php.path` of one or more Omeka Classic installations. Optimized for cPanel/shared hosting environments.

# how to use it

Upload the `set-omeka-php-path.sh` file to your server (manually or with something like...):

```
$ wget https://raw.githubusercontent.com/ebellempire/set-omeka-php-path/refs/heads/main/set-omeka-php-path.sh
```

Then just run it like any shell script, including one or more arguments indicating the location of the installation(s):

```
$ bash set-omeka-php-path.sh path/to/omeka
$ bash set-omeka-php-path.sh path/to/omeka another/path/to/omeka
```

It's a good idea to start with a dry run. You can also skip detection and choose the PHP binary yourself, which is handy on servers that don't use cPanel:

```
$ bash set-omeka-php-path.sh -n path/to/omeka                  # dry run
$ bash set-omeka-php-path.sh -b ea-php74 path/to/omeka         # use /usr/local/bin/ea-php74
```

# what it does

Omeka runs some long jobs in the background (batch editing all items, rebuilding the search index, plugins like CSV Import) using the PHP binary set as `background.php.path` in `application/config/config.ini`. If that binary is a different PHP version than the one the site runs on, those jobs can fail without telling anyone, so this script makes the two match.

For each argument, the script first checks that it's a valid Omeka installation (we just look for the `bootstrap.php` file and make sure it includes the string `OMEKA_VERSION`). On cPanel servers, it asks cPanel's own `php` command (`/usr/local/bin/php`) which PHP version the site uses, which is the version set for that domain in MultiPHP Manager (or the server default), and turns that into a path like `/usr/local/bin/ea-php82`. After making sure that's a working command-line PHP, it changes only the `background.php.path` line (or adds one under `[site]` if it's missing) and uses PHP's own INI parser to confirm the new value is there and nothing else changed. Only then does it save `config.ini`, keeping a copy of the original next to it as `config.bak-YYYYmmdd-HHMMSS.ini` (the name ends in `.ini` so Omeka's `.htaccess` keeps it private). If the path is already correct, the file is left alone. It will also warn you if an `.htaccess` file sets a different PHP version than MultiPHP Manager does. The output while it's processing is useful but minimal. When it's done, it prints out a basic summary of what changed, what was already set, what was skipped, and anything that needs a closer look. That's it.

# what it doesn't do

The script does not change which PHP version a site uses. It does not install PHP versions or extensions. It does not work out a site's PHP version on servers without cPanel; there it falls back to the server's default `php`, which may not be what the site actually runs (check the PHP version on Omeka's System Information page at `/admin/system-info` and rerun with `-b` if it's different). Changing PHP versions is a job for MultiPHP Manager or your hosting provider, and for everything else there's the `-b` option.

# maintenance

Run the script again after Installatron (or other auto-) updates, which overwrite the previous `config.ini` file, and/or whenever a site's PHP version changes, whether you changed it in MultiPHP Manager or your hosting provider did (for example, when retiring an old version). Each change leaves a backup next to `config.ini`; once you're happy, you can clear them out with something like `rm path/to/omeka/application/config/config.bak-*.ini`. To undo a change, just copy a backup over `config.ini` with `cp`, which keeps the file's owner and permissions.

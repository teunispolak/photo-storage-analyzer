# Making an extract

This guide helps you make an extract of your photo storage on your Mac. An extract describes your photos: their names, folders, sizes and dates, together with a copy of your Lightroom Classic catalog. It does not contain the photos themselves. We use it to plan the move of your photos to their new storage.

Everything happens in Terminal, the Mac app for typing commands. You don't need any experience with it. Each step tells you what to type, and you can copy the commands from this guide and paste them into Terminal.

The first part you do once. After that, making an extract takes a few minutes.

## Before you start: things you do once

### 1. Open Terminal

Press Command and Space together, type `Terminal`, and press Return. A window opens with a line of text ending in `%`. That is where you paste the commands.

To run a command, paste it into the window and press Return. Wait until the `%` line appears again before you paste the next one.

### 2. Install the developer tools

Paste this command:

```
git --version
```

If your Mac shows a version number, such as `git version 2.39.5`, the tools are already installed and you can go to the next step.

If a window appears asking to install the command line developer tools, click Install and accept the licence. The installation takes a few minutes. When it is done, paste the command again; it now shows a version number.

### 3. Get the extract tool

Paste this command:

```
git clone https://github.com/teunispolak/photo-storage-analyzer ~/photo-storage-analyzer
```

This downloads the tool into a folder called `photo-storage-analyzer` in your home folder. It only reads your files and never changes your photos or your catalog.

### 4. Send us two locations

We need to know where your Lightroom catalog and your photos are. You can copy each location as text in Finder:

1. **Your Lightroom catalog.** In Lightroom Classic, choose Catalog Settings (in the Lightroom Classic menu), open the General tab, and click Show next to Location. Finder opens with your catalog file selected; its name ends in `.lrcat`.
2. **Your photo folder.** This is the top folder that holds your photos, often on an external drive. In Lightroom's Library, right-click the top folder in the Folders panel and choose Show in Finder.

For each of the two, select it in Finder, hold the Option key, right-click it, and choose Copy "…" as Pathname. Paste the result into an email to us. Do this for both, and send the email.

If your photos are spread over more than one top folder, send us each of them.

### 5. Save the settings file we send you

We reply with a small file called `settings.env`. It tells the tool which catalog and which photo folder to use. Save it in your Downloads folder, then paste this command:

```
mkdir -p ~/photo-analysis && mv ~/Downloads/settings.env ~/photo-analysis/
```

This creates a folder called `photo-analysis` in your home folder and moves the settings file into it.

### 6. Check that the tool can read your catalog

Close Lightroom Classic first. Then paste these two commands, one at a time:

```
cd ~/photo-storage-analyzer
```

```
./psa check-catalog
```

The tool prints a list of checks. If the last line reads `Structure ok`, all is well. If you see lines starting with `FAIL`, please send us a screenshot of the window (press Shift, Command and 5 together, then click Capture).

## Making an extract

Do this whenever we ask you for an extract.

### 1. Prepare

Connect the drive with your photos, and close Lightroom Classic.

### 2. Make the extract

Open Terminal and paste these two commands, one at a time:

```
cd ~/photo-storage-analyzer
```

```
./psa extract
```

The first time, your Mac may ask whether Terminal may access files on a removable volume, or in a folder such as Pictures. Click Allow; the tool needs this to read the list of your photos.

The tool first makes a copy of your catalog. As soon as it prints `Lightroom may be restarted now`, you can open Lightroom Classic again. The tool then reads the list of your photo files, which can take a few minutes for a large collection. It is done when it prints `Extract complete`.

### 3. Send us the extract

Paste this command to open the folder that holds your extract:

```
open ~/photo-analysis/extracts
```

Finder shows a folder whose name starts with the names from your settings file and ends with the date and time, for example `smith_anna_20261118T091500Z`. Right-click it and choose Compress to make a zip file of it, and send us the zip file in the way we agreed.

The extract contains file and folder names, sizes and dates, and a copy of your Lightroom catalog. It contains no photos.

### 4. Tidy up

Once we confirm that we received your extract, you can move the folder and its zip file to the Bin. The tool never removes anything itself.

## If something goes wrong

- **The tool says Lightroom is still open.** Quit Lightroom Classic (Lightroom Classic menu, Quit Lightroom Classic) and run `./psa extract` again.
- **The tool says it cannot find a folder or the catalog.** Check that the drive with your photos is connected, and run `./psa extract` again. If it keeps happening, send us a screenshot.
- **You clicked Don't Allow when your Mac asked for access.** Open System Settings, go to Privacy & Security, then Files and Folders, find Terminal, and switch on Removable Volumes (and Pictures, if listed). Then run `./psa extract` again.
- **`zsh: no such file or directory: ./psa`.** Terminal is not in the tool's folder. Paste `cd ~/photo-storage-analyzer` first.
- **Anything else.** Send us a screenshot of the Terminal window (Shift, Command and 5, then Capture). We will help you from there.

The tool may print a line about checking for updates before it starts. That is normal: it keeps itself up to date.

//
//  FinderSync.m
//  MacNewFileFinderExtension
//
//  Created by Louie Yin on 2026-01-25.
//

#import "FinderSync.h"

@interface FinderSync ()
- (FIMenuKind)menuKindForSender:(id)sender;
- (BOOL)menuKindRepresentsSelection:(FIMenuKind)kind;
- (NSArray<NSString *> *)pathsForMenuKind:(FIMenuKind)kind;
- (void)updateDirectoryURLs;
- (void)revealAndRenameURL:(NSURL *)fileURL;
@end

@implementation FinderSync

- (instancetype)init {
    self = [super init];

    // Monitor root filesystem and all mounted volumes (including USB drives).
    // Finder Sync extensions don't cross volume mount points, so each mounted
    // volume has to be added explicitly.
    // Note: iCloud Drive is not supported due to macOS Sonoma+ limitations.
    [self updateDirectoryURLs];

    // Volume mounts and unmounts are picked up from NSWorkspace notifications.
    // There used to be a 3-second poll instead; reassigning directoryURLs makes
    // Finder rebuild the extension's menus, so polling added nothing but
    // needless menu teardown while a context menu was open.
    NSNotificationCenter *workspaceCenter = [[NSWorkspace sharedWorkspace] notificationCenter];
    for (NSString *name in @[NSWorkspaceDidMountNotification,
                             NSWorkspaceDidUnmountNotification,
                             NSWorkspaceDidRenameVolumeNotification]) {
        [workspaceCenter addObserver:self
                            selector:@selector(volumesDidChange:)
                                name:name
                              object:nil];
    }

    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

- (void)volumesDidChange:(NSNotification *)notification {
    [self updateDirectoryURLs];
}

- (void)updateDirectoryURLs {
    // Enumerate volumes off the main thread: the enumeration can block, and
    // running it on the main queue stalls menu building.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableSet *urls = [NSMutableSet setWithObject:[NSURL fileURLWithPath:@"/"]];

        // Add all mounted volumes (covers USB drives, external drives, etc.)
        NSArray *volumeURLs = [[NSFileManager defaultManager]
            mountedVolumeURLsIncludingResourceValuesForKeys:nil
                                                    options:NSVolumeEnumerationSkipHiddenVolumes];
        for (NSURL *volumeURL in volumeURLs) {
            [urls addObject:volumeURL];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // Reassigning directoryURLs makes Finder tear down and rebuild the
            // extension's menus, which closes an open context menu and its
            // submenu. Only reassign when the set actually changed.
            NSSet *current = [FIFinderSyncController defaultController].directoryURLs;
            if (current && [current isEqualToSet:urls]) {
                return;
            }
            [FIFinderSyncController defaultController].directoryURLs = urls;
        });
    });
}

#pragma mark - Primary Finder Sync protocol methods

- (void)beginObservingDirectoryAtURL:(NSURL *)url {
    // Called when user opens a directory in Finder
}


- (void)endObservingDirectoryAtURL:(NSURL *)url {
    // Called when user closes a directory in Finder
}

- (void)requestBadgeIdentifierForURL:(NSURL *)url {
    // Not used - no badge icons needed
}

#pragma mark - Menu and toolbar item support

- (NSString *)toolbarItemName {
    return NSLocalizedString(@"New File", nil);
}

- (NSString *)toolbarItemToolTip {
    return NSLocalizedString(@"MacNewFileFinderExtension: Click the toolbar item for a menu.", nil);
}

- (NSImage *)toolbarItemImage {
    return [NSImage imageNamed:NSImageNameAddTemplate];
}

- (NSMenu *)menuForMenuKind:(FIMenuKind)whichMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    // Automatic enabling validates every item through validateMenuItem:. The
    // "New File" parent has no action, so validation would disable it, and
    // Finder closes the whole menu when a disabled submenu parent is clicked.
    // Keep the items enabled exactly as set here instead.
    menu.autoenablesItems = NO;

    // The menu kind is stashed on each item so the actions can tell whether
    // they were invoked on selected items or on the container background.
    // tag is biased by one because 0 is NSMenuItem's default tag.
    NSInteger menuKindTag = (NSInteger)whichMenu + 1;

    // Add "Copy Path" menu item
    NSMenuItem *copyPathItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Copy Path", nil) action:@selector(copyPathToClipboard:) keyEquivalent:@""];
    copyPathItem.target = self;
    copyPathItem.tag = menuKindTag;
    NSImage *copyIcon = [NSImage imageNamed:@"copy"];
    copyIcon.template = YES;
    copyPathItem.image = copyIcon;
    [menu addItem:copyPathItem];

    // Add "Open Terminal" menu item
    NSMenuItem *openTerminalItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Open New Terminal", nil) action:@selector(openTerminalAtPath:) keyEquivalent:@""];
    openTerminalItem.target = self;
    openTerminalItem.tag = menuKindTag;
    NSImage *terminalIcon = [NSImage imageNamed:@"terminal"];
    terminalIcon.template = YES;
    openTerminalItem.image = terminalIcon;
    [menu addItem:openTerminalItem];

    // Create submenu for New File options
    NSMenu *submenu = [[NSMenu alloc] initWithTitle:@""];
    submenu.autoenablesItems = NO;

    // Each entry is title, action, and asset-catalog icon name.
    NSArray<NSArray<NSString *> *> *fileTypes = @[
        @[NSLocalizedString(@"Text File", nil), NSStringFromSelector(@selector(createNewTextFile:)), @"edit"],
        @[NSLocalizedString(@"Markdown File", nil), NSStringFromSelector(@selector(createNewMarkdownFile:)), @"document"],
        @[NSLocalizedString(@"Microsoft Word Document", nil), NSStringFromSelector(@selector(createNewWordDocument:)), @"word"],
        @[NSLocalizedString(@"Microsoft Excel Spreadsheet", nil), NSStringFromSelector(@selector(createNewExcelDocument:)), @"excel"],
        @[NSLocalizedString(@"Microsoft PowerPoint Presentation", nil), NSStringFromSelector(@selector(createNewPowerPointDocument:)), @"powerpoint"],
        @[NSLocalizedString(@"Pages Document", nil), NSStringFromSelector(@selector(createNewPagesDocument:)), @"pages"],
        @[NSLocalizedString(@"Numbers Spreadsheet", nil), NSStringFromSelector(@selector(createNewNumbersDocument:)), @"numbers"],
        @[NSLocalizedString(@"Keynote Presentation", nil), NSStringFromSelector(@selector(createNewKeynoteDocument:)), @"keynote"],
    ];

    for (NSArray<NSString *> *fileType in fileTypes) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:fileType[0]
                                                     action:NSSelectorFromString(fileType[1])
                                              keyEquivalent:@""];
        item.target = self;
        item.tag = menuKindTag;
        item.enabled = YES;
        NSImage *icon = [NSImage imageNamed:fileType[2]];
        icon.template = YES;
        item.image = icon;
        [submenu addItem:item];
    }

    // Add "New File" submenu
    // A submenu parent must stay enabled while keeping a nil action, like
    // Finder's own parent items: clicking it then does nothing and the menu
    // stays open, instead of the click being handled as a dismissing action.
    NSMenuItem *mainItem = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"New File", nil) action:nil keyEquivalent:@""];
    NSImage *mainIcon = [NSImage imageNamed:@"add"];
    mainItem.image = mainIcon;
    mainItem.enabled = YES;
    mainItem.submenu = submenu;
    [menu addItem:mainItem];

    return menu;
}

// Reveal the new file and start renaming it, like Finder's own "New Folder".
// The reveal selects the file, so Shift+Return opens its rename field; plain
// Return would open the document instead.
- (void)revealAndRenameURL:(NSURL *)fileURL {
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[fileURL]];

    // The reveal is asynchronous, so poll until Finder actually reports the new
    // file as selected before sending the keystroke; a fixed sleep raced the
    // reveal and sent the keystroke into the void. The script needs
    // Automation/Accessibility permission; without it the file stays selected
    // and can be renamed manually. The result (or TCC error code) is logged so
    // failures are diagnosable instead of silent.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *fileName = fileURL.lastPathComponent;

        // The sandboxed extension cannot read Finder's selection (err -1728),
        // so polling is impossible; send the keystroke blind after giving the
        // reveal time to land. Needs Automation/Accessibility permission.
        NSString *source = [NSString stringWithFormat:
            @"delay 1.0\n"
            "tell application \"System Events\" to keystroke return using shift down\n"
            "return \"sent\""];

        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
        NSDictionary *errorDict = nil;
        [script executeAndReturnError:&errorDict];
        NSString *debugOut;
        if (errorDict) {
            NSLog(@"Failed to start renaming (%@): %@",
                  [errorDict objectForKey:@"ErrorNumber"] ?: @"unknown", errorDict);
            debugOut = [NSString stringWithFormat:@"[%@] target=%@ SCRIPT-ERROR: %@\n",
                [[NSDate date] description], fileName,
                [errorDict objectForKey:@"ErrorNumber"] ?: @"unknown"];
        } else {
            debugOut = [NSString stringWithFormat:@"[%@] target=%@ KEYSENT\n",
                [[NSDate date] description], fileName];
        }
        NSString *debugPath = @"/tmp/mnf-rename-debug.log";
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:debugPath];
        if (!fh) {
            [debugOut writeToFile:debugPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[debugOut dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    });
}

- (FIMenuKind)menuKindForSender:(id)sender {
    // Only tag survives Finder's copy of the menu, so the menu kind is
    // recovered from it. tag is biased by one because 0 is the default.
    if ([sender isKindOfClass:[NSMenuItem class]]) {
        NSMenuItem *item = (NSMenuItem *)sender;
        if (item.tag > 0) {
            return (FIMenuKind)(item.tag - 1);
        }
    }
    return FIMenuKindContextualMenuForContainer;
}

// Whether the menu was opened on something the user selected, as opposed to
// the folder background or the toolbar button
- (BOOL)menuKindRepresentsSelection:(FIMenuKind)kind {
    return kind == FIMenuKindContextualMenuForItems ||
           kind == FIMenuKindContextualMenuForSidebar;
}

// Paths to copy: the selected items when the menu was opened on a selection,
// otherwise the folder the menu was opened in. Empty selection arrays are
// ignored so a stale selection never leaks into a container-level menu.
- (NSArray<NSString *> *)pathsForMenuKind:(FIMenuKind)kind {
    FIFinderSyncController *controller = [FIFinderSyncController defaultController];

    if ([self menuKindRepresentsSelection:kind]) {
        NSArray<NSURL *> *selectedURLs = [controller selectedItemURLs];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSURL *url in selectedURLs) {
            if (url.path.length > 0) {
                [paths addObject:url.path];
            }
        }
        if (paths.count > 0) {
            return paths;
        }
    }

    NSString *targetPath = [controller targetedURL].path;
    return targetPath.length > 0 ? @[targetPath] : @[];
}

// Function to copy selected item paths, or the current directory when
// the menu was opened on the folder background
- (void)copyPathToClipboard:(id)sender {
    NSArray<NSString *> *paths = [self pathsForMenuKind:[self menuKindForSender:sender]];

    if (paths.count == 0) {
        NSLog(@"Copy Path: no target path available");
        return;
    }

    NSString *clipboardText = [paths componentsJoinedByString:@"\n"];
    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    [pasteboard setString:clipboardText forType:NSPasteboardTypeString];

    NSLog(@"Copied path to clipboard: %@", clipboardText);
}

// Function to open Terminal at the selected folder, or at the folder the menu
// was opened in. For a selection of files this is their parent directory.
- (void)openTerminalAtPath:(id)sender {
    FIFinderSyncController *controller = [FIFinderSyncController defaultController];
    NSURL *targetURL = [controller targetedURL];

    if (!targetURL) {
        NSLog(@"No target URL");
        return;
    }

    NSString *path = targetURL.path;

    // A single selected folder should open in that folder, not its parent
    if ([self menuKindRepresentsSelection:[self menuKindForSender:sender]]) {
        NSArray<NSURL *> *selectedURLs = [controller selectedItemURLs];
        if (selectedURLs.count == 1) {
            NSURL *selectedURL = selectedURLs.firstObject;
            NSNumber *isDirectory = nil;
            if ([selectedURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL] &&
                isDirectory.boolValue) {
                path = selectedURL.path;
            }
        }
    }

    if (path.length == 0) {
        NSLog(@"No target URL");
        return;
    }
    NSString *escapedPath = [path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    NSString *scriptSource = [NSString stringWithFormat:
        @"do shell script \"open -a Terminal '%@'\"", escapedPath];

    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorDict = nil;
    [script executeAndReturnError:&errorDict];

    if (errorDict) {
        NSLog(@"Failed to open Terminal: %@", errorDict);
    } else {
        NSLog(@"Opened Terminal at: %@", path);
    }
}

// Function to create new Word document
- (void)createNewWordDocument:(id)sender {
    NSURL *targetURL = [[FIFinderSyncController defaultController] targetedURL];

    if (!targetURL) {
        NSLog(@"No target URL");\
        return;
    }

    // Build unique filename
    NSString *baseName = NSLocalizedString(@"Untitled", nil);
    NSString *extension = @"docx";
    NSString *filePath = [targetURL.path stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@.%@", baseName, extension]];

    NSFileManager *fm = [NSFileManager defaultManager];
    int counter = 1;
    while ([fm fileExistsAtPath:filePath]) {
        NSString *fileName = [NSString stringWithFormat:@"%@ (%d).%@", baseName, counter, extension];
        filePath = [targetURL.path stringByAppendingPathComponent:fileName];
        counter++;
    }

    // Create blank .docx using shell script
    // .docx is a zip file containing XML files
    // Includes styles.xml for Calibri 11pt default font
    NSString *escapedPath = [filePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    NSString *scriptSource = [NSString stringWithFormat:
        @"do shell script \""
        "TMPDIR=$(mktemp -d) && "
        "mkdir -p \\\"$TMPDIR/_rels\\\" \\\"$TMPDIR/word/_rels\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Types xmlns=\\\"http://schemas.openxmlformats.org/package/2006/content-types\\\"><Default Extension=\\\"rels\\\" ContentType=\\\"application/vnd.openxmlformats-package.relationships+xml\\\"/><Default Extension=\\\"xml\\\" ContentType=\\\"application/xml\\\"/><Override PartName=\\\"/word/document.xml\\\" ContentType=\\\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\\\"/><Override PartName=\\\"/word/styles.xml\\\" ContentType=\\\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\\\"/></Types>' > \\\"$TMPDIR/[Content_Types].xml\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Relationships xmlns=\\\"http://schemas.openxmlformats.org/package/2006/relationships\\\"><Relationship Id=\\\"rId1\\\" Type=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\\\" Target=\\\"word/document.xml\\\"/></Relationships>' > \\\"$TMPDIR/_rels/.rels\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Relationships xmlns=\\\"http://schemas.openxmlformats.org/package/2006/relationships\\\"><Relationship Id=\\\"rId1\\\" Type=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\\\" Target=\\\"styles.xml\\\"/></Relationships>' > \\\"$TMPDIR/word/_rels/document.xml.rels\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><w:styles xmlns:w=\\\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\\\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\\\"Calibri\\\" w:hAnsi=\\\"Calibri\\\" w:cs=\\\"Calibri\\\"/><w:sz w:val=\\\"22\\\"/><w:szCs w:val=\\\"22\\\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\\\"0\\\" w:line=\\\"276\\\" w:lineRule=\\\"auto\\\"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type=\\\"paragraph\\\" w:default=\\\"1\\\" w:styleId=\\\"Normal\\\"><w:name w:val=\\\"Normal\\\"/><w:rPr><w:rFonts w:ascii=\\\"Calibri\\\" w:hAnsi=\\\"Calibri\\\" w:cs=\\\"Calibri\\\"/><w:sz w:val=\\\"22\\\"/><w:szCs w:val=\\\"22\\\"/></w:rPr></w:style></w:styles>' > \\\"$TMPDIR/word/styles.xml\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><w:document xmlns:w=\\\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\\\"><w:body><w:p><w:r><w:t></w:t></w:r></w:p></w:body></w:document>' > \\\"$TMPDIR/word/document.xml\\\" && "
        "cd \\\"$TMPDIR\\\" && zip -r '%@' . && "
        "rm -rf \\\"$TMPDIR\\\""
        "\"", escapedPath];

    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorDict = nil;
    [script executeAndReturnError:&errorDict];

    if (errorDict) {
        NSLog(@"Failed to create Word document: %@", errorDict);
    } else {
        NSLog(@"Created: %@", filePath);
        [self revealAndRenameURL:[NSURL fileURLWithPath:filePath]];
    }
}

// Function to create new Excel document
- (void)createNewExcelDocument:(id)sender {
    NSURL *targetURL = [[FIFinderSyncController defaultController] targetedURL];

    if (!targetURL) {
        NSLog(@"No target URL");
        return;
    }

    // Build unique filename
    NSString *baseName = NSLocalizedString(@"Untitled", nil);
    NSString *extension = @"xlsx";
    NSString *filePath = [targetURL.path stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@.%@", baseName, extension]];

    NSFileManager *fm = [NSFileManager defaultManager];
    int counter = 1;
    while ([fm fileExistsAtPath:filePath]) {
        NSString *fileName = [NSString stringWithFormat:@"%@ (%d).%@", baseName, counter, extension];
        filePath = [targetURL.path stringByAppendingPathComponent:fileName];
        counter++;
    }

    // Create blank .xlsx using shell script
    // .xlsx is a zip file containing XML files
    // Includes styles.xml for Calibri 11pt default font
    NSString *escapedPath = [filePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    NSString *scriptSource = [NSString stringWithFormat:
        @"do shell script \""
        "TMPDIR=$(mktemp -d) && "
        "mkdir -p \\\"$TMPDIR/_rels\\\" \\\"$TMPDIR/xl/_rels\\\" \\\"$TMPDIR/xl/worksheets\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Types xmlns=\\\"http://schemas.openxmlformats.org/package/2006/content-types\\\"><Default Extension=\\\"rels\\\" ContentType=\\\"application/vnd.openxmlformats-package.relationships+xml\\\"/><Default Extension=\\\"xml\\\" ContentType=\\\"application/xml\\\"/><Override PartName=\\\"/xl/workbook.xml\\\" ContentType=\\\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\\\"/><Override PartName=\\\"/xl/worksheets/sheet1.xml\\\" ContentType=\\\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\\\"/><Override PartName=\\\"/xl/styles.xml\\\" ContentType=\\\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\\\"/></Types>' > \\\"$TMPDIR/[Content_Types].xml\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Relationships xmlns=\\\"http://schemas.openxmlformats.org/package/2006/relationships\\\"><Relationship Id=\\\"rId1\\\" Type=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\\\" Target=\\\"xl/workbook.xml\\\"/></Relationships>' > \\\"$TMPDIR/_rels/.rels\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><workbook xmlns=\\\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\\\" xmlns:r=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\\\"><sheets><sheet name=\\\"Sheet1\\\" sheetId=\\\"1\\\" r:id=\\\"rId1\\\"/></sheets></workbook>' > \\\"$TMPDIR/xl/workbook.xml\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Relationships xmlns=\\\"http://schemas.openxmlformats.org/package/2006/relationships\\\"><Relationship Id=\\\"rId1\\\" Type=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\\\" Target=\\\"worksheets/sheet1.xml\\\"/><Relationship Id=\\\"rId2\\\" Type=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\\\" Target=\\\"styles.xml\\\"/></Relationships>' > \\\"$TMPDIR/xl/_rels/workbook.xml.rels\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><styleSheet xmlns=\\\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\\\"><fonts count=\\\"1\\\"><font><sz val=\\\"11\\\"/><name val=\\\"Calibri\\\"/><family val=\\\"2\\\"/></font></fonts><fills count=\\\"2\\\"><fill><patternFill patternType=\\\"none\\\"/></fill><fill><patternFill patternType=\\\"gray125\\\"/></fill></fills><borders count=\\\"1\\\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\\\"1\\\"><xf numFmtId=\\\"0\\\" fontId=\\\"0\\\" fillId=\\\"0\\\" borderId=\\\"0\\\"/></cellStyleXfs><cellXfs count=\\\"1\\\"><xf numFmtId=\\\"0\\\" fontId=\\\"0\\\" fillId=\\\"0\\\" borderId=\\\"0\\\" xfId=\\\"0\\\"/></cellXfs></styleSheet>' > \\\"$TMPDIR/xl/styles.xml\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><worksheet xmlns=\\\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\\\"><sheetData/></worksheet>' > \\\"$TMPDIR/xl/worksheets/sheet1.xml\\\" && "
        "cd \\\"$TMPDIR\\\" && zip -r '%@' . && "
        "rm -rf \\\"$TMPDIR\\\""
        "\"", escapedPath];

    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorDict = nil;
    [script executeAndReturnError:&errorDict];

    if (errorDict) {
        NSLog(@"Failed to create Excel document: %@", errorDict);
    } else {
        NSLog(@"Created: %@", filePath);
        [self revealAndRenameURL:[NSURL fileURLWithPath:filePath]];
    }
}

// Function to create new PowerPoint document
- (void)createNewPowerPointDocument:(id)sender {
    NSURL *targetURL = [[FIFinderSyncController defaultController] targetedURL];

    if (!targetURL) {
        NSLog(@"No target URL");
        return;
    }

    // Build unique filename
    NSString *baseName = NSLocalizedString(@"Untitled", nil);
    NSString *extension = @"pptx";
    NSString *filePath = [targetURL.path stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@.%@", baseName, extension]];

    NSFileManager *fm = [NSFileManager defaultManager];
    int counter = 1;
    while ([fm fileExistsAtPath:filePath]) {
        NSString *fileName = [NSString stringWithFormat:@"%@ (%d).%@", baseName, counter, extension];
        filePath = [targetURL.path stringByAppendingPathComponent:fileName];
        counter++;
    }

    // Create blank .pptx using shell script
    // .pptx is a zip file containing XML files
    NSString *escapedPath = [filePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    NSString *scriptSource = [NSString stringWithFormat:
        @"do shell script \""
        "TMPDIR=$(mktemp -d) && "
        "mkdir -p \\\"$TMPDIR/_rels\\\" \\\"$TMPDIR/ppt/_rels\\\" \\\"$TMPDIR/ppt/slides\\\" \\\"$TMPDIR/ppt/slideLayouts\\\" \\\"$TMPDIR/ppt/slideMasters\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Types xmlns=\\\"http://schemas.openxmlformats.org/package/2006/content-types\\\"><Default Extension=\\\"rels\\\" ContentType=\\\"application/vnd.openxmlformats-package.relationships+xml\\\"/><Default Extension=\\\"xml\\\" ContentType=\\\"application/xml\\\"/><Override PartName=\\\"/ppt/presentation.xml\\\" ContentType=\\\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\\\"/><Override PartName=\\\"/ppt/slides/slide1.xml\\\" ContentType=\\\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\\\"/></Types>' > \\\"$TMPDIR/[Content_Types].xml\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Relationships xmlns=\\\"http://schemas.openxmlformats.org/package/2006/relationships\\\"><Relationship Id=\\\"rId1\\\" Type=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\\\" Target=\\\"ppt/presentation.xml\\\"/></Relationships>' > \\\"$TMPDIR/_rels/.rels\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><p:presentation xmlns:p=\\\"http://schemas.openxmlformats.org/presentationml/2006/main\\\" xmlns:r=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\\\"><p:sldIdLst><p:sldId id=\\\"256\\\" r:id=\\\"rId1\\\"/></p:sldIdLst></p:presentation>' > \\\"$TMPDIR/ppt/presentation.xml\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><Relationships xmlns=\\\"http://schemas.openxmlformats.org/package/2006/relationships\\\"><Relationship Id=\\\"rId1\\\" Type=\\\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\\\" Target=\\\"slides/slide1.xml\\\"/></Relationships>' > \\\"$TMPDIR/ppt/_rels/presentation.xml.rels\\\" && "
        "echo '<?xml version=\\\"1.0\\\" encoding=\\\"UTF-8\\\"?><p:sld xmlns:p=\\\"http://schemas.openxmlformats.org/presentationml/2006/main\\\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\\\"1\\\" name=\\\"\\\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld></p:sld>' > \\\"$TMPDIR/ppt/slides/slide1.xml\\\" && "
        "cd \\\"$TMPDIR\\\" && zip -r '%@' . && "
        "rm -rf \\\"$TMPDIR\\\""
        "\"", escapedPath];

    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorDict = nil;
    [script executeAndReturnError:&errorDict];

    if (errorDict) {
        NSLog(@"Failed to create PowerPoint document: %@", errorDict);
    } else {
        NSLog(@"Created: %@", filePath);
        [self revealAndRenameURL:[NSURL fileURLWithPath:filePath]];
    }
}

// Function to create new Pages document
- (void)createNewPagesDocument:(id)sender {
    NSURL *targetURL = [[FIFinderSyncController defaultController] targetedURL];

    if (!targetURL) {
        NSLog(@"No target URL");
        return;
    }

    // Build unique filename
    NSString *baseName = NSLocalizedString(@"Untitled", nil);
    NSString *extension = @"pages";
    NSString *filePath = [targetURL.path stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@.%@", baseName, extension]];

    NSFileManager *fm = [NSFileManager defaultManager];
    int counter = 1;
    while ([fm fileExistsAtPath:filePath]) {
        NSString *fileName = [NSString stringWithFormat:@"%@ (%d).%@", baseName, counter, extension];
        filePath = [targetURL.path stringByAppendingPathComponent:fileName];
        counter++;
    }

    // Get the blank template from the bundle
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *templatePath = [bundle pathForResource:@"Blank" ofType:@"pages"];

    if (!templatePath) {
        NSLog(@"Failed to find Blank.pages template in bundle");
        return;
    }

    // Copy template to destination using AppleScript (to bypass sandbox)
    NSString *escapedTemplate = [templatePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *escapedDest = [filePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    NSString *scriptSource = [NSString stringWithFormat:
        @"do shell script \"cp -R '%@' '%@'\"", escapedTemplate, escapedDest];

    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorDict = nil;
    [script executeAndReturnError:&errorDict];

    if (errorDict) {
        NSLog(@"Failed to create Pages document: %@", errorDict);
    } else {
        NSLog(@"Created: %@", filePath);
        [self revealAndRenameURL:[NSURL fileURLWithPath:filePath]];
    }
}

// Function to create new Numbers document
- (void)createNewNumbersDocument:(id)sender {
    NSURL *targetURL = [[FIFinderSyncController defaultController] targetedURL];

    if (!targetURL) {
        NSLog(@"No target URL");
        return;
    }

    // Build unique filename
    NSString *baseName = NSLocalizedString(@"Untitled", nil);
    NSString *extension = @"numbers";
    NSString *filePath = [targetURL.path stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@.%@", baseName, extension]];

    NSFileManager *fm = [NSFileManager defaultManager];
    int counter = 1;
    while ([fm fileExistsAtPath:filePath]) {
        NSString *fileName = [NSString stringWithFormat:@"%@ (%d).%@", baseName, counter, extension];
        filePath = [targetURL.path stringByAppendingPathComponent:fileName];
        counter++;
    }

    // Get the blank template from the bundle
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *templatePath = [bundle pathForResource:@"Blank" ofType:@"numbers"];

    if (!templatePath) {
        NSLog(@"Failed to find Blank.numbers template in bundle");
        return;
    }

    // Copy template to destination using AppleScript (to bypass sandbox)
    NSString *escapedTemplate = [templatePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *escapedDest = [filePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    NSString *scriptSource = [NSString stringWithFormat:
        @"do shell script \"cp -R '%@' '%@'\"", escapedTemplate, escapedDest];

    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorDict = nil;
    [script executeAndReturnError:&errorDict];

    if (errorDict) {
        NSLog(@"Failed to create Numbers document: %@", errorDict);
    } else {
        NSLog(@"Created: %@", filePath);
        [self revealAndRenameURL:[NSURL fileURLWithPath:filePath]];
    }
}

// Function to create new Keynote document
- (void)createNewKeynoteDocument:(id)sender {
    NSURL *targetURL = [[FIFinderSyncController defaultController] targetedURL];

    if (!targetURL) {
        NSLog(@"No target URL");
        return;
    }

    // Build unique filename
    NSString *baseName = NSLocalizedString(@"Untitled", nil);
    NSString *extension = @"key";
    NSString *filePath = [targetURL.path stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@.%@", baseName, extension]];

    NSFileManager *fm = [NSFileManager defaultManager];
    int counter = 1;
    while ([fm fileExistsAtPath:filePath]) {
        NSString *fileName = [NSString stringWithFormat:@"%@ (%d).%@", baseName, counter, extension];
        filePath = [targetURL.path stringByAppendingPathComponent:fileName];
        counter++;
    }

    // Get the blank template from the bundle
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSString *templatePath = [bundle pathForResource:@"Blank" ofType:@"key"];

    if (!templatePath) {
        NSLog(@"Failed to find Blank.key template in bundle");
        return;
    }

    // Copy template to destination using AppleScript (to bypass sandbox)
    NSString *escapedTemplate = [templatePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *escapedDest = [filePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];

    NSString *scriptSource = [NSString stringWithFormat:
        @"do shell script \"cp -R '%@' '%@'\"", escapedTemplate, escapedDest];

    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorDict = nil;
    [script executeAndReturnError:&errorDict];

    if (errorDict) {
        NSLog(@"Failed to create Keynote document: %@", errorDict);
    } else {
        NSLog(@"Created: %@", filePath);
        [self revealAndRenameURL:[NSURL fileURLWithPath:filePath]];
    }
}

// Function to create new text file
- (void)createNewTextFile:(id)sender {
    [self createFileWithExtension:@"txt"];
}

// Function to create new Markdown file
- (void)createNewMarkdownFile:(id)sender {
    [self createFileWithExtension:@"md"];
}

// Helper function to create empty files
- (void)createFileWithExtension:(NSString *)extension {
    NSURL *targetURL = [[FIFinderSyncController defaultController] targetedURL];

    if (!targetURL) {
        NSLog(@"No target URL");
        return;
    }

    // Create filename
    NSString *baseName = NSLocalizedString(@"Untitled", nil);
    NSString *filePath = [targetURL.path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", baseName, extension]];

    // If "Untitled" already exists, add a number to it
    NSFileManager *fm = [NSFileManager defaultManager];
    int counter = 1;

    while ([fm fileExistsAtPath:filePath]) {
        NSString *fileName = [NSString stringWithFormat:@"%@ (%d).%@", baseName, counter, extension];
        filePath = [targetURL.path stringByAppendingPathComponent:fileName];
        counter++;
    }

    // Use AppleScript to create a new file and bypass sandboxing permissions
    NSString *escapedPath = [filePath stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSString *scriptSource = [NSString stringWithFormat:@"do shell script \"touch '%@'\"", escapedPath];

    // Run AppleScript
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorDict = nil;
    [script executeAndReturnError:&errorDict];

    if (errorDict) {
        NSLog(@"Failed: %@", errorDict);
    } else {
        NSLog(@"Created: %@", filePath);
        [self revealAndRenameURL:[NSURL fileURLWithPath:filePath]];
    }
}

@end

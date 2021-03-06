//
//  TODocumentPickerTableViewController.m
//
//  Copyright 2015 Timothy Oliver. All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to
//  deal in the Software without restriction, including without limitation the
//  rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
//  sell copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
//  OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
//  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
//  IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "TODocumentPickerDefines.h"

#import "TODocumentPickerTableViewController.h"
#import "TODocumentPickerTableView.h"
#import "TODocumentPickerHeaderView.h"
#import "TODocumentPickerItemManager.h"
#import "TODocumentPickerItem.h"

@interface TODocumentPickerTableViewController () <UISearchBarDelegate, UITableViewDelegate, UITableViewDataSource>

/* View management */
@property (nonatomic, strong) TODocumentPickerHeaderView *headerView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingView;
@property (nonatomic, strong) UILabel *feedbackLabel;
@property (nonatomic, strong) UILabel *toolBarLabel;
@property (nonatomic, strong) UIBarButtonItem *doneButton;
@property (nonatomic, strong) UIBarButtonItem *selectAllButton;
@property (nonatomic, strong) UIBarButtonItem *chooseButton;

/* Edit mode toggle */
@property (nonatomic, strong) UIBarButtonItem *selectButton;
@property (nonatomic, strong) UIBarButtonItem *cancelButton;

/* Edit mode toolbar items */
@property (nonatomic, strong) NSArray *nonEditingToolbarItems;
@property (nonatomic, strong) NSArray *editingToolbarItems;

/* Cell label fonts */
@property (nonatomic, strong) UIFont *cellFolderFont;
@property (nonatomic, strong) UIFont *cellFileFont;

/* Item Manager */
@property (nonatomic, strong) TODocumentPickerItemManager *itemManager;

/* Currently visible sorting mode */
@property (nonatomic, assign) TODocumentPickerSortType sortingType;

/* Single use flag to check for the first time we appear onscreen */
@property (nonatomic, assign) BOOL viewInitiallyAppeared;

/* State tracking */
@property (nonatomic, readonly) BOOL sectionIndexVisible; /* Check to see if we have enough items to warrant an index. */
@property (nonatomic, readonly) BOOL allCellsSelected;

/* Serial queue for posting updates to the items property asynchronously. */
@property (nonatomic, strong) dispatch_queue_t serialQueue;

/* Show dummy content labels */
- (void)showFeedbackLabelIfNeeded;

/* Setup positions and constraints */
- (void)resetHeaderConstraints;
- (void)resetTableViewInitialOffset;
- (void)resetAfterInitialItemLoad;

/* User interaction callbacks */
- (void)refreshControlTriggered;
- (void)selectButtonTapped;
- (void)doneButtonTapped;
- (void)selectAllButtonTapped;
- (void)chooseButtonTapped;

/* Visual content updates */
- (void)updateContent;
- (void)updateFooterLabel;
- (void)updateToolbarItems;
- (void)updateBarButtonsAnimated:(BOOL)animated;

@end

@implementation TODocumentPickerTableViewController

#pragma mark - View Setup -
- (instancetype)init
{
    if (self = [super init]) {
        _cellFolderFont = [UIFont boldSystemFontOfSize:17.0f];//[UIFont fontWithName:@"HelveticaNeue-Medium" size:17.0f];
        _cellFileFont   = [UIFont systemFontOfSize:17.0f];
        
        _itemManager = [[TODocumentPickerItemManager alloc] init];
        
        _serialQueue = dispatch_queue_create("TODocumentPickerViewController.itemBuilderQueue", DISPATCH_QUEUE_SERIAL);
    }
    
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    CGRect frame = CGRectZero;
    __block TODocumentPickerTableViewController *blockSelf = self;
    
    /* Configure table */
    self.tableView = [[TODocumentPickerTableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.rowHeight = 52.0f;
    self.tableView.sectionIndexBackgroundColor = self.view.backgroundColor;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;

    /* Table item manager setup */
    self.itemManager.tableView = self.tableView;
    self.itemManager.contentReloadedHandler = ^{ [blockSelf updateContent]; };
    
    /* Configure header view and components */
    self.headerView = [TODocumentPickerHeaderView new];
    self.headerView.searchTextChangedHandler = ^(NSString *searchText) {
        blockSelf.itemManager.searchString = searchText;
        [blockSelf showFeedbackLabelIfNeeded];
    };
    
    UIView *tableHeaderView = [[UIView alloc] initWithFrame:self.headerView.bounds];
    tableHeaderView.backgroundColor = self.view.backgroundColor;
    [tableHeaderView addSubview:self.headerView];
    self.tableView.tableHeaderView = tableHeaderView;

    /* Handler for changing sort type */
    self.headerView.sortControl.sortTypeChangedHandler = ^{
        blockSelf.sortingType = self.headerView.sortControl.sortingType;
    };
    
    /* Create the incidental loading indicator. */
    self.loadingView = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.loadingView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin;
    frame = self.loadingView.frame;
    frame.origin.x = (CGRectGetWidth(self.tableView.bounds) - CGRectGetWidth(frame)) * 0.5f;
    frame.origin.y = CGRectGetHeight(self.headerView.frame) + ((self.tableView.rowHeight - CGRectGetHeight(frame)) * 0.5f) + self.tableView.rowHeight;
    self.loadingView.frame = frame;
    [self.tableView addSubview:self.loadingView];
    [self.loadingView startAnimating];
    
    /* Toolbar files/folders count label */
    self.toolBarLabel = [[UILabel alloc] initWithFrame:(CGRect){0,0,215,44}];
    self.toolBarLabel.font = [UIFont systemFontOfSize:12.0f];
    self.toolBarLabel.textColor = self.navigationController.navigationBar.titleTextAttributes[NSForegroundColorAttributeName];
    self.toolBarLabel.textAlignment = NSTextAlignmentCenter;
    self.toolBarLabel.text = NSLocalizedString(@"Loading...", nil);
    
    /* Toolbar button elements */
    self.doneButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Done", nil) style:UIBarButtonItemStyleDone target:self action:@selector(doneButtonTapped)];
    UIBarButtonItem *spaceItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *labelItem = [[UIBarButtonItem alloc] initWithCustomView:self.toolBarLabel];
    self.nonEditingToolbarItems = @[self.doneButton, spaceItem, labelItem, spaceItem, spaceItem];
    
    self.selectAllButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Select All", @"") style:UIBarButtonItemStylePlain target:self action:@selector(selectAllButtonTapped)];
    UIBarButtonItem *actionItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:nil action:nil];
    self.chooseButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Choose", @"") style:UIBarButtonItemStyleDone target:self action:@selector(chooseButtonTapped)];
    self.editingToolbarItems = @[self.selectAllButton, spaceItem, actionItem, spaceItem, self.chooseButton];
    actionItem.enabled = NO;
    
    self.selectButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Select", nil) style:UIBarButtonItemStylePlain target:self action:@selector(selectButtonTapped)];
    self.cancelButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Cancel", nil) style:UIBarButtonItemStyleDone target:self action:@selector(selectButtonTapped)];
    self.navigationItem.rightBarButtonItem = self.selectButton;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    if (!self.viewInitiallyAppeared) {
        /* On iPad, the frame of the table view isn't finalised until we hit this call. */
        /* So rebuild the items once here to ensure they're laid out correctly. */
        [self.itemManager reloadItems];
        
        /* Scroll the table downwards so the header view is initially hidden. */
        [self resetTableViewInitialOffset];
        
        self.viewInitiallyAppeared = YES;
    }
}

- (void)resetAfterInitialItemLoad
{
    if (self.refreshControl == nil) {
        self.refreshControl = [[UIRefreshControl alloc] init];
        [self.refreshControl addTarget:self action:@selector(refreshControlTriggered) forControlEvents:UIControlEventValueChanged];
    }

    [self.refreshControl endRefreshing];
    
    if (self.loadingView) {
        [self.loadingView removeFromSuperview];
        self.loadingView = nil;
    }
}

- (void)resetTableViewInitialOffset
{
    CGPoint contentOffset = self.tableView.contentOffset;
    contentOffset.y = -self.tableView.contentInset.top + CGRectGetHeight(self.headerView.frame);
    self.tableView.contentOffset = contentOffset;
}

- (void)resetHeaderConstraints
{
    NSInteger width = 0;
    
    if (self.sortingType <= TODocumentPickerSortTypeNameDescending) {
        //Extract the section index view
        UIView *indexView = nil;
        for (UIView *view in self.tableView.subviews) {
            if ([NSStringFromClass([view class]) rangeOfString:@"ViewIndex"].length == 0)
                continue;
            
            indexView = view;
            break;
        }
        
        width = (NSInteger)CGRectGetWidth(indexView.frame);
    }
    
    //TODO: Figure out how to do this in autolayout
    CGFloat newWidth = CGRectGetWidth(self.tableView.bounds) - width;
    if ((NSInteger)newWidth == (NSInteger)CGRectGetWidth(self.headerView.frame))
        return;
    
    CGRect frame = self.headerView.frame;
    frame.size.width = newWidth;
    self.headerView.frame = frame;
}

- (void)setupFeedbackLabel
{
    if (self.feedbackLabel != nil)
        return;
    
    self.feedbackLabel = [[UILabel alloc] initWithFrame:(CGRect){0,0,20,44}];
    self.feedbackLabel.font = [UIFont systemFontOfSize:14.0f];
    self.feedbackLabel.textAlignment = NSTextAlignmentCenter;
    self.feedbackLabel.textColor = [UIColor colorWithWhite:0.7f alpha:1.0f];
    
}

#pragma mark - Event Handling -
- (void)refreshControlTriggered
{
    if (self.refreshControlTriggeredHandler)
        self.refreshControlTriggeredHandler();
    else
        [self.refreshControl endRefreshing];
}

- (void)selectButtonTapped
{
    [self setEditing:!self.editing animated:YES];
    [self updateBarButtonsAnimated:YES];
}

- (void)updateBarButtonsAnimated:(BOOL)animated
{
    [self.navigationItem setRightBarButtonItem:(self.editing ? self.cancelButton : self.selectButton) animated:animated];
    
    if (self.navigationController.viewControllers.count > 1)
        [self.navigationItem setHidesBackButton:self.editing animated:animated];
}

- (void)selectAllButtonTapped
{
    if (self.editing == NO)
        return;
    
    BOOL selected = (self.allCellsSelected == NO);
    
    for (NSInteger i = 0; i < [self.tableView numberOfSections]; i++) {
        for (NSInteger j = 0; j < [self.tableView numberOfRowsInSection:i]; j++) {
            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:j inSection:i];
            
            if (selected)
                [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
            else
                [self.tableView deselectRowAtIndexPath:indexPath animated:NO];
        }
    }
    
    [self updateToolbarItems];
}

- (void)doneButtonTapped
{
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)chooseButtonTapped
{
    
}

#pragma mark - Table View Data Source -
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return [self.itemManager numberOfSections];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self.itemManager numberOfRowsForSection:section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    static NSString *identifier = @"TableCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        Class tableViewCellClass = self.tableViewCellClass;
        if (tableViewCellClass == nil)
            tableViewCellClass = [UITableViewCell class];
        
        cell = [[tableViewCellClass alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.6f alpha:1.0f];
    }
        
    TODocumentPickerItem *item = [self.itemManager itemForIndexPath:indexPath];
    cell.textLabel.text         = item.fileName;
    cell.detailTextLabel.text   = item.localizedMetadata;
    cell.accessoryType          = item.isFolder ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.textLabel.font         = item.isFolder ? self.cellFolderFont : self.cellFileFont;
    cell.imageView.image        = item.isFolder ? self.folderIcon : self.defaultIcon;
    
    return cell;
}

- (NSArray *)sectionIndexTitlesForTableView:(UITableView *)tableView
{
    return [self.itemManager sectionIndexTitles];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return [self.itemManager titleForHeaderInSection:section];
}

- (NSInteger)tableView:(UITableView *)tableView sectionForSectionIndexTitle:(NSString *)title atIndex:(NSInteger)index
{
    if ([title isEqualToString:@"{search}"]) {
        [self.tableView setContentOffset:CGPointZero animated:NO];
        return -1;
    }
        
    return [self.itemManager sectionForSectionIndexAtIndex:index];
}

#pragma mark - Table View Delegate -
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.editing) {
        [self updateToolbarItems];
        return;
    }
    
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    TODocumentPickerItem *item = [self.itemManager itemForIndexPath:indexPath];
    if (item.isFolder) {
        NSString *newFilePath = [self.filePath stringByAppendingPathComponent:item.fileName];
        [(TODocumentPickerViewController *)self.navigationController pushNewViewControllerForFilePath:newFilePath animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (self.editing)
        [self updateToolbarItems];
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    [self.headerView dismissKeyboard];
}

#pragma mark - Accessors -  
- (void)setItems:(NSArray *)items
{
    if (items == self.itemManager.items)
        return;
    
    //if the items are actually 0, reset the views now,
    //but still set the value via the serial queue to ensure no collisions
    if (items.count == 0) {
        [self resetAfterInitialItemLoad];
        [self showFeedbackLabelIfNeeded];
    }
    
    // perform sorting on a separate queue to ensure no hiccups in the refresh UI
    dispatch_async(self.serialQueue, ^{
        self.itemManager.items = items;
        
        //Force the end refresh animation to happen on another iteration of the run loop
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self resetAfterInitialItemLoad];
        });
    });
}

- (NSArray *)items
{
    return self.itemManager.items;
}

- (void)setSortingType:(TODocumentPickerSortType)sortingType
{
    self.itemManager.sortingType = sortingType;
}

- (TODocumentPickerSortType)sortingType
{
    return self.itemManager.sortingType;
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];
    [self updateContent];
}

- (BOOL)allCellsSelected
{
    //If we're mid search, compare the count to the item manager
    if (self.itemManager.searchString.length > 0)
        return [self.tableView indexPathsForSelectedRows].count == [self.itemManager numberOfRowsForSection:0];
    
    return [self.tableView indexPathsForSelectedRows].count == self.items.count;
}

#pragma mark - Update View Content -
- (void)updateContent
{
    [self resetHeaderConstraints];
    [self updateFooterLabel];
    [self updateToolbarItems];
    
    self.navigationItem.rightBarButtonItem.enabled = (self.items.count > 0);
}

- (void)showFeedbackLabelIfNeeded
{
    self.feedbackLabel.hidden = YES;
    
    //Cancel if searching AND resulting rows is greater than one
    if (self.itemManager.searchString.length > 0 && [self.itemManager numberOfRowsForSection:0] > 0)
        return;
    
    //Cnacel if not searching and items are present
    if (self.itemManager.searchString.length == 0 && self.items.count > 0)
        return;
    
    if (self.feedbackLabel == nil) {
        self.feedbackLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        self.feedbackLabel.font = [UIFont systemFontOfSize:16.0f];
        self.feedbackLabel.textColor = [UIColor colorWithWhite:0.8f alpha:1.0f];
        self.feedbackLabel.textAlignment = NSTextAlignmentCenter;
        [self.tableView addSubview:self.feedbackLabel];
    }
    
    self.feedbackLabel.hidden = NO;
    
    if (self.headerView.searchBar.text.length > 0)
        self.feedbackLabel.text = NSLocalizedString(@"No Results Found", @"");
    else
        self.feedbackLabel.text = NSLocalizedString(@"Folder is Empty", @"");
    
    [self.feedbackLabel sizeToFit];
    
    CGRect frame = self.feedbackLabel.frame;
    frame.origin.x = (CGRectGetWidth(self.tableView.bounds) - CGRectGetWidth(frame)) * 0.5f;
    frame.origin.y = CGRectGetHeight(self.headerView.frame) + ((self.tableView.rowHeight - CGRectGetHeight(frame)) * 0.5f) + self.tableView.rowHeight;
    self.feedbackLabel.frame = frame;
}

- (void)updateFooterLabel
{
    NSInteger numberOfFolders = 0, numberOfFiles = 0;
    
    for (TODocumentPickerItem *item in self.items) {
        if (item.isFolder)
            numberOfFolders++;
        else
            numberOfFiles++;
    }
    
    //'folder' or 'folders' depending on number
    NSString *pluralFolders = (numberOfFolders == 1) ? NSLocalizedString(@"folder", nil) : NSLocalizedString(@"folders", nil);
    NSString *pluralFiles = (numberOfFiles == 1) ? NSLocalizedString(@"file", nil) : NSLocalizedString(@"files", nil);
    
    NSString *labelText = nil;
    if (numberOfFolders && numberOfFiles)
        labelText = [NSString stringWithFormat:@"%ld %@, %ld %@", (long)numberOfFolders, pluralFolders, (long)numberOfFiles, pluralFiles];
    else if (numberOfFolders)
        labelText = [NSString stringWithFormat:@"%ld %@", (long)numberOfFolders, pluralFolders];
    else if (numberOfFiles)
        labelText = [NSString stringWithFormat:@"%ld %@", (long)numberOfFiles, pluralFiles];
    else {
        if (self.loadingView && self.loadingView.hidden == NO)
            labelText = NSLocalizedString(@"Loading...", nil);
        else
            labelText = NSLocalizedString(@"No files or folders found", nil);
    }
        
    self.toolBarLabel.text = labelText;
}

- (void)updateToolbarItems
{
    if (self.editing == NO && self.toolbarItems != self.nonEditingToolbarItems)
        [self setToolbarItems:self.nonEditingToolbarItems animated:YES];
    else if (self.editing && self.toolbarItems != self.editingToolbarItems)
        [self setToolbarItems:self.editingToolbarItems animated:YES];
    
    if (self.editing == NO)
        return;
    
    self.chooseButton.enabled = ([self.tableView indexPathsForSelectedRows].count > 0);
    self.selectAllButton.title = self.allCellsSelected ? NSLocalizedString(@"Select None", @"") : NSLocalizedString(@"Select All", @"");
}

@end

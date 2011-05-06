#import "ViFileCompletion.h"
#import "ViError.h"
#include "logging.h"

@implementation ViFileCompletion

- (ViFileCompletion *)initWithRelativeURL:(NSURL *)aURL
{
	if ((self = [super init]) != nil) {
		relURL = aURL;
	}
	return self;
}

- (void)appendFilter:(NSString *)string toPattern:(NSMutableString *)pattern
{
	NSUInteger i;
	for (i = 0; i < [string length]; i++) {
		unichar c = [string characterAtIndex:i];
		if (i != 0)
			[pattern appendString:@".*?"];
		[pattern appendFormat:@"(%s%C)", c == '.' ? "\\" : "", c];
	}
}

- (id<ViDeferred>)completionsForString:(NSString *)path
			       options:(NSString *)options
			    onResponse:(void (^)(NSArray *, NSError *))responseCallback
{
	DEBUG(@"relURL is %@", relURL);
	NSString *basePath = nil;
	NSURL *baseURL = nil;
	NSURL *url = nil;
	BOOL isAbsoluteURL = NO;
	if ([path rangeOfString:@"://"].location != NSNotFound) {
		isAbsoluteURL = YES;
		url = [NSURL URLWithString:
		    [path stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
		if (url == nil) {
			responseCallback(nil, [ViError errorWithFormat:
			    @"failed to parse url %@", path]);
			return nil;
		}
		if ([[url path] length] == 0) {
			DEBUG(@"no path in url %@", url);
			url = [[NSURL URLWithString:@"/" relativeToURL:url] absoluteURL];
			DEBUG(@"added path in url %@", url);
			baseURL = url;
		} else if ([path hasSuffix:@"/"])
			baseURL = url;
		else
			baseURL = [url URLByDeletingLastPathComponent];
	} else if ([path isAbsolutePath]) {
		if ([path hasSuffix:@"/"])
			basePath = path;
		else
			basePath = [path stringByDeletingLastPathComponent];
		url = [[NSURL URLWithString:
		    [path stringByExpandingTildeInPath] relativeToURL:relURL] absoluteURL];
	} else {
		if ([path hasSuffix:@"/"])
			basePath = path;
		else
			basePath = [path stringByDeletingLastPathComponent];
		url = [[NSURL URLWithString:
		    [path stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]
			     relativeToURL:relURL] absoluteURL];
	}

	NSString *suffix = @"";
	if (isAbsoluteURL && ![[url absoluteString] hasSuffix:@"/"]) {
		suffix = [path lastPathComponent];
		url = [url URLByDeletingLastPathComponent];
	} else if (![path hasSuffix:@"/"] && ![path isEqualToString:@""]) {
		suffix = [path lastPathComponent];
		url = [url URLByDeletingLastPathComponent];
	}

	BOOL fuzzySearch = ([options rangeOfString:@"f"].location != NSNotFound);
	BOOL fuzzyTrigger = ([options rangeOfString:@"F"].location != NSNotFound);
	ViRegexp *rx = nil;
	if (fuzzyTrigger) { /* Fuzzy completion trigger. */
		NSMutableString *pattern = [NSMutableString string];
		[pattern appendString:@"^"];
		[self appendFilter:suffix toPattern:pattern];
		[pattern appendString:@".*$"];
		rx = [[ViRegexp alloc] initWithString:pattern options:ONIG_OPTION_IGNORECASE];
	}

	DEBUG(@"suffix = [%@], rx = [%@], url = %@", suffix, rx, url);

	int opts = 0;
	if ([url isFileURL]) {
		/* Check if local filesystem is case sensitive. */
		NSNumber *isCaseSensitive;
		if ([url getResourceValue:&isCaseSensitive
				   forKey:NSURLVolumeSupportsCaseSensitiveNamesKey
				    error:NULL] && ![isCaseSensitive intValue] == 1) {
			opts |= NSCaseInsensitiveSearch;
		}
	}

	ViURLManager *um = [ViURLManager defaultManager];

	return [um contentsOfDirectoryAtURL:url onCompletion:^(NSArray *directoryContents, NSError *error) {
		if (error) {
			responseCallback(nil, error);
			return;
		}

		NSMutableArray *matches = [NSMutableArray array];
		for (NSArray *entry in directoryContents) {
			NSString *filename = [entry objectAtIndex:0];
			NSDictionary *attributes = [entry objectAtIndex:1];

			NSRange r = NSIntersectionRange(NSMakeRange(0, [suffix length]),
			    NSMakeRange(0, [filename length]));
			BOOL match;
			ViRegexpMatch *m = nil;
			if (fuzzyTrigger)
				match = ((m = [rx matchInString:filename]) != nil);
			else
				match = [filename compare:suffix options:opts range:r] == NSOrderedSame;

			if (match) {
				/* Only show dot-files if explicitly requested. */
				if ([filename hasPrefix:@"."] && ![suffix hasPrefix:@"."])
					continue;

				NSString *s;
				if (isAbsoluteURL)
					s = [[baseURL URLByAppendingPathComponent:filename] absoluteString];
				else
					s = [basePath stringByAppendingPathComponent:filename];

				if ([[attributes fileType] isEqualToString:NSFileTypeDirectory])
					s = [s stringByAppendingString:@"/"];

				ViCompletion *c;
				if (fuzzySearch) {
					c = [ViCompletion completionWithContent:s fuzzyMatch:m];
					c.prefixLength = [path length];
				} else
					c = [ViCompletion completionWithContent:s prefixLength:[path length]];
				[matches addObject:c];
			}
		}
		responseCallback(matches, nil);
	}];
}

@end

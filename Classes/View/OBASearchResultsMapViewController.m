/**
 * Copyright (C) 2009 bdferris <bdferris@onebusaway.org>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *         http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "OBASearchResultsMapViewController.h"
#import "OBARoute.h"
#import "OBAStopV2.h"
#import "OBARouteV2.h"
#import "OBAAgencyWithCoverageV2.h"
#import "OBAStopAnnotation.h"
#import "OBAGenericAnnotation.h"
#import "OBAAgencyWithCoverage.h"
#import "OBANavigationTargetAnnotation.h"
#import "OBASphericalGeometryLibrary.h"
#import "OBAUIKit.h"
#import "OBASearchViewController.h"
#import "OBAProgressIndicatorView.h"
#import "OBASearchResultsListViewController.h"
#import "OBAStopViewController.h"
#import "OBACoordinateBounds.h"
#import "OBASearchControllerImpl.h"
#import "OBALogger.h"

// Radius in meters
static const double kDefaultMapRadius = 100;
static const double kMinMapRadius = 150;
static const double kMaxLatDeltaToShowStops = 0.008;
static const double kRegionScaleFactor = 1.5;
static const double kMinRegionDeltaToDetectUserDrag = 50;

static const double kRegionChangeRequestsTimeToLive = 3.0;

static const double kMaxMapDistanceFromCurrentLocation = 750;
static const double kPaddingScaleFactor = 1.075;
static const NSUInteger kShowNClosestStops = 4;

static const double kStopsInRegionRefreshDelayOnDrag = 0.5;
static const double kStopsInRegionRefreshDelayOnLocate = 0.1;


typedef enum  {
	OBARegionChangeRequestTypeNone=0,
	OBARegionChangeRequestTypeCurrentLocation=1,
	OBARegionChangeRequestTypeSearchResult=2
} OBARegionChangeRequestType;


@interface OBARegionChangeRequest : NSObject
{
	NSDate * _timestamp;
	OBARegionChangeRequestType _type;
	MKCoordinateRegion _region;
}

- (id) initWithRegion:(MKCoordinateRegion)region type:(OBARegionChangeRequestType)type;
- (double) compareRegion:(MKCoordinateRegion)region;

@property (nonatomic,readonly) OBARegionChangeRequestType type;
@property (nonatomic,readonly) MKCoordinateRegion region;
@property (nonatomic,readonly) NSDate * timestamp;

@end


@interface OBASearchResultsMapViewController (Private)

- (void) loadIcons;
- (void) centerMapOnMostRecentLocation;
- (void) refreshCurrentLocation;


- (void) setMapRegion:(MKCoordinateRegion)region requestType:(OBARegionChangeRequestType)requestType;
- (void) setMapRegionWithRequest:(OBARegionChangeRequest*)request;

- (OBARegionChangeRequest*) getBestRegionChangeRequestForRegion:(MKCoordinateRegion)region;

- (void) scheduleRefreshOfStopsInRegion:(NSTimeInterval)interval location:(CLLocation*)location;
- (NSTimeInterval) getRefreshIntervalForLocationAccuracy:(CLLocation*)location;
- (void) refreshStopsInRegion;

- (void) reloadData;
- (CLLocation*) currentLocation;
- (UIImage*) getIconForStop:(OBAStopV2*)stop;
- (NSString*) getRouteIconTypeForStop:(OBAStopV2*)stop;

- (void) setAnnotationsFromResults;
- (void) setRegionFromResults;

- (NSString*) computeLabelForCurrentResults;

- (MKCoordinateRegion) computeRegionForCurrentResults:(BOOL*)needsUpdate;
- (MKCoordinateRegion) computeRegionForStops:(NSArray*)stops;
- (MKCoordinateRegion) computeRegionForNClosestStops:(NSArray*)stops center:(CLLocation*)location numberOfStops:(NSUInteger)numberOfStops;
- (MKCoordinateRegion) computeRegionForPlacemarks:(NSArray*)stops;
- (MKCoordinateRegion) computeRegionForStops:(NSArray*)stops center:(CLLocation*)location;
- (MKCoordinateRegion) computeRegionForNearbyStops:(NSArray*)stops;
- (MKCoordinateRegion) computeRegionForPlacemarks:(NSArray*)placemarks andStops:(NSArray*)stops;
- (MKCoordinateRegion) computeRegionForAgenciesWithCoverage:(NSArray*)agenciesWithCoverage;

- (MKCoordinateRegion) getLocationAsRegion:(CLLocation*)location;

- (void) checkResults;
- (void) checkNoRouteResults;
- (void) checkNoPlacemarksResults;
- (void) showNoResultsAlertWithTitle:(NSString*)title prompt:(NSString*)prompt;
- (BOOL) controllerIsVisibleAndActive;

@end


@implementation OBASearchResultsMapViewController

@synthesize appContext = _appContext;
@synthesize mapView = _mapView;
@synthesize searchTypeControl = _searchTypeControl;
@synthesize listButton = _listButton;
@synthesize filterToolbar = _filterToolbar;

-(void) dealloc {
	[_appContext release];

	[_pendingRegionChangeRequest release];
	[_appliedRegionChangeRequests release];
	
	[_activityIndicatorView release];
	
	[_searchController cancelOpenConnections];
	[_searchController release];
	
	[_mapView release];
	[_listButton release];
	[_searchTypeControl release];

	[_locationAnnotation release];
	[_mapAnnotations release];
	 
	[_stopIcons release];
	[_defaultStopIcon release];
	[_mostRecentLocation release];
	
	[_networkErrorAlertViewDelegate release];
		
	[super dealloc];
}

- (void) viewDidLoad {
	[super viewDidLoad];

	[self loadIcons];
	[self centerMapOnMostRecentLocation];
	
	_searchController = [[OBASearchControllerImpl alloc] initWithAppContext:_appContext];
	
	_networkErrorAlertViewDelegate = [[OBANetworkErrorAlertViewDelegate alloc] initWithContext:_appContext];
	
	CGRect indicatorBounds = CGRectMake(12, 12, 32, 32);
	_activityIndicatorView = [[UIActivityIndicatorView alloc] initWithFrame:indicatorBounds];
	_activityIndicatorView.activityIndicatorViewStyle = UIActivityIndicatorViewStyleGray;
	_activityIndicatorView.hidesWhenStopped = TRUE;
	[self.view addSubview:_activityIndicatorView];
	
	_locationAnnotation = nil;
	_mapAnnotations = [[NSMutableArray alloc] init];
	
	_firstView = TRUE;
	_autoCenterOnCurrentLocation = TRUE;
	_currentlyChangingRegion = FALSE;
	
	CLLocationCoordinate2D p = {0,0};
	_mostRecentRegion = MKCoordinateRegionMake(p, MKCoordinateSpanMake(0,0));
	
	_refreshTimer = nil;
	
	_pendingRegionChangeRequest = nil;
	_appliedRegionChangeRequests = [[NSMutableArray alloc] init];
	
	_searchController.delegate = self;	
	_searchController.progress.delegate = self;

    self.filterToolbar = [[OBASearchResultsMapFilterToolbar alloc] initWithDelegate:self];
}

- (void)viewDidUnload {
    [self.filterToolbar release];
    [super viewDidUnload];
}

- (void)onFilterClear {
    [self.filterToolbar hideWithAnimated:YES];
    [self refreshStopsInRegion];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
	
	OBALocationManager * lm = _appContext.locationManager;
	[lm addDelegate:self];
	[lm startUpdatingLocation];
	[_searchTypeControl setEnabled:lm.locationServicesEnabled forSegmentAtIndex:0];
	
	if( _firstView ) {
		[self reloadData];
		_firstView = FALSE;
	}

    // show the UIToolbar at the bottom of the view controller
	//
    NSString * searchFilterDesc = [_searchController searchFilterString];
    if (searchFilterDesc != nil)
        [self.filterToolbar showWithDescription:searchFilterDesc animated:NO];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
    
	[_appContext.locationManager stopUpdatingLocation];
	[_appContext.locationManager removeDelegate:self];

    [self.filterToolbar hideWithAnimated:NO];
}

#pragma mark OBANavigationTargetAware

- (OBANavigationTarget*) navigationTarget {
	return [_searchController getSearchTarget];
}

-(void) setNavigationTarget:(OBANavigationTarget*)target {
	[_searchController searchWithTarget:target];
    
    NSString * searchFilterDesc = [_searchController searchFilterString];
    if (searchFilterDesc != nil)
        [self.filterToolbar showWithDescription:searchFilterDesc animated:NO];
}

#pragma mark OBASearchControllerDelegate Methods

- (void) handleSearchControllerStarted:(OBASearchControllerSearchType)searchType {
	if( ! (searchType == OBASearchControllerSearchTypeNone || searchType == OBASearchControllerSearchTypeRegion) ) {
		OBALogDebug(@"search started: unsetting _autoCenterOnCurrentLocation");
		_autoCenterOnCurrentLocation = FALSE;
	}	
}

- (void) handleSearchControllerUpdate:(OBASearchControllerResult*)result {
	[self reloadData];
}

- (void) handleSearchControllerError:(NSError*)error {

	NSString * domain = [error domain];
	
	// We get this message because the user clicked "Don't allow" on using the current location.  Unfortunately,
	// this error gets propagated to us when the app isn't active (because the alert asking about location is).
	
	if( domain == kCLErrorDomain && [error code] == kCLErrorDenied ) {
        UIAlertView * view = [[[UIAlertView alloc] init] autorelease];
		view.title = @"Location Information";
		view.message = @"Location information is disabled for this app.  Finding nearby stops using your current location will not function.";
		[view addButtonWithTitle:@"Dismiss"];
		view.cancelButtonIndex = 0;
		[view show];
		return;
	}
	
	if( ! [self controllerIsVisibleAndActive] )
		return;
	
	if( domain == NSURLErrorDomain ) {
		UIAlertView * view = [[[UIAlertView alloc] init] autorelease];
		view.title = @"Error connecting";
		view.message = @"There was a problem with your Internet connection.\n\nPlease check your network connection or contact us if you think the problem is on our end.";
		view.delegate = _networkErrorAlertViewDelegate;
		[view addButtonWithTitle:@"Contact Us"];
		[view addButtonWithTitle:@"Dismiss"];
		view.cancelButtonIndex = 1;
		[view show];
	}
}

#pragma mark OBALocationManagerDelegate Methods

- (void) locationManager:(OBALocationManager *)manager didUpdateLocation:(CLLocation *)location {
	[self refreshCurrentLocation];
}

- (void) locationManager:(OBALocationManager *)manager didFailWithError:(NSError*)error {
	if( [error domain] == kCLErrorDomain && [error code] == kCLErrorDenied ) {
		[_searchTypeControl setEnabled:FALSE forSegmentAtIndex:0];
	}
}

#pragma mark OBAProgressIndicatorDelegate

- (void) progressUpdated {
	
	id<OBAProgressIndicatorSource> progress = _searchController.progress;

	if( progress.inProgress ) {
		[_activityIndicatorView startAnimating];
	}
	else {
		[_activityIndicatorView stopAnimating];
	}
}

#pragma mark MKMapViewDelegate Methods

- (void)mapView:(MKMapView *)mapView regionWillChangeAnimated:(BOOL)animated {
	_currentlyChangingRegion = TRUE;
}

- (void)mapView:(MKMapView *)mapView regionDidChangeAnimated:(BOOL)animated {

	_currentlyChangingRegion = FALSE;
	
	// We need to figure out if this region change came from the user dragging the map
	// or from an actual request we instigated.  The easiest way to tell is to 
	MKCoordinateRegion region = _mapView.region;	
	OBARegionChangeRequestType type = OBARegionChangeRequestTypeNone;
	
	OBALogDebug(@"=== regionDidChangeAnimated: requests=%d",[_appliedRegionChangeRequests count]);
	OBALogDebug(@"region=%@", [OBASphericalGeometryLibrary regionAsString:region]);
	
	OBARegionChangeRequest * request = [self getBestRegionChangeRequestForRegion:region];
	if( request ) {
		double score = [request compareRegion:region];
		OBALogDebug(@"regionDidChangeAnimated: score=%f", score);
		OBALogDebug(@"subregion=%@", [OBASphericalGeometryLibrary regionAsString:request.region]);
		if( score < kMinRegionDeltaToDetectUserDrag )
			type = request.type;
	}

	_autoCenterOnCurrentLocation = (type == OBARegionChangeRequestTypeCurrentLocation);
	OBALogDebug(@"regionDidChangeAnimated: setting _autoCenterOnCurrentLocation to %d", _autoCenterOnCurrentLocation);
	
	if( _autoCenterOnCurrentLocation && _pendingRegionChangeRequest) {
		OBALogDebug(@"applying pending reqest");
		[self setMapRegionWithRequest:_pendingRegionChangeRequest];
	}
	else if( type == OBARegionChangeRequestTypeCurrentLocation ) {
		OBALocationManager * lm = _appContext.locationManager;
		double refreshInterval = [self getRefreshIntervalForLocationAccuracy:lm.currentLocation];
		[self scheduleRefreshOfStopsInRegion:refreshInterval location:lm.currentLocation];
	}
	else if( type == OBARegionChangeRequestTypeNone ) {
		if( _searchController.searchType == OBASearchControllerSearchTypeNone || _searchController.searchType == OBASearchControllerSearchTypeRegion || _searchController.searchType == OBASearchControllerSearchTypePlacemark)
			[self scheduleRefreshOfStopsInRegion:kStopsInRegionRefreshDelayOnDrag location:nil];
	}
		
	_pendingRegionChangeRequest = [NSObject releaseOld:_pendingRegionChangeRequest retainNew:nil];
}

- (MKAnnotationView *)mapView:(MKMapView *)mapView viewForAnnotation:(id<MKAnnotation>)annotation {
	
	if( [annotation isKindOfClass:[OBAStopV2 class]] ) {
		
		OBAStopV2 * stop = (OBAStopV2*)annotation;
		static NSString * viewId = @"StopView";
		
		MKAnnotationView * view = [mapView dequeueReusableAnnotationViewWithIdentifier:viewId];
		if( view == nil ) {
			view = [[[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId] autorelease];
		}
		view.canShowCallout = TRUE;
		view.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
		view.image = [self getIconForStop:stop];
		return view;
	}
	else if( [annotation isKindOfClass:[OBAPlacemark class]] ) {
		static NSString * viewId = @"NavigationTargetView";
		MKPinAnnotationView * view = (MKPinAnnotationView*) [mapView dequeueReusableAnnotationViewWithIdentifier:viewId];
		if( view == nil ) {
			view = [[[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId] autorelease];
		}
		
		view.canShowCallout = TRUE;
		
		if( _searchController.searchType == OBASearchControllerSearchTypeAddress)
			view.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
		else
			view.rightCalloutAccessoryView = nil;
		return view;
	}
	else if( [annotation isKindOfClass:[OBANavigationTargetAnnotation class]] ) {
		static NSString * viewId = @"NavigationTargetView";
		MKPinAnnotationView * view = (MKPinAnnotationView*) [mapView dequeueReusableAnnotationViewWithIdentifier:viewId];
		if( view == nil ) {
			view = [[[MKPinAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId] autorelease];
		}
		
		OBANavigationTargetAnnotation * nav = annotation;
		
		view.canShowCallout = TRUE;
		
		if( nav.target )
			view.rightCalloutAccessoryView = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
		else
			view.rightCalloutAccessoryView = nil;
		
		return view;
	}
	else if( [annotation isKindOfClass:[OBAGenericAnnotation class]] ) {
		
		OBAGenericAnnotation * ga = annotation;
		if( [@"currentLocation" isEqual:ga.context] ) {
			static NSString * viewId = @"CurrentLocationView";
			
			MKAnnotationView * view = [mapView dequeueReusableAnnotationViewWithIdentifier:viewId];
			if( view == nil ) {
				view = [[[MKAnnotationView alloc] initWithAnnotation:annotation reuseIdentifier:viewId] autorelease];
			}
			view.canShowCallout = FALSE;
			view.image = [UIImage imageNamed:@"BlueMarker.png"];
			return view;
		}
	}
	
	return nil;
}

- (void) mapView:(MKMapView *)mapView annotationView:(MKAnnotationView *)view calloutAccessoryControlTapped:(UIControl *)control {
	
	id annotation = view.annotation;
	
	if( [annotation isKindOfClass:[OBAStopV2 class] ] ) {		
		OBAStopV2 * stop = annotation;
		OBAStopViewController * vc = [[OBAStopViewController alloc] initWithApplicationContext:_appContext stopId:stop.stopId];
		[self.navigationController pushViewController:vc animated:TRUE];
		[vc release];
	}
	else if( [annotation isKindOfClass:[OBAPlacemark class]] ) {
		OBAPlacemark * placemark = annotation;
		OBANavigationTarget * target = [OBASearchControllerFactory getNavigationTargetForSearchPlacemark:placemark];
		[_searchController searchWithTarget:target];
	}
}

#pragma mark UIAlertViewDelegate Methods

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
	if( buttonIndex == 0 ) {
		OBANavigationTarget * target = [OBASearchControllerFactory getNavigationTargetForSearchAgenciesWithCoverage];
		[_appContext navigateToTarget:target];
	}
}


-(IBAction) onCrossHairsButton:(id)sender {	
	OBALogDebug(@"setting auto center on current location");
	_autoCenterOnCurrentLocation = TRUE;
	[self refreshCurrentLocation];
}


-(IBAction) onListButton:(id)sender {
	OBASearchControllerResult * result = _searchController.result;
	if( result ) {
		
		// Prune down the results to show only what's currently in the map view
		result = [result resultsInRegion:_mapView.region];
		
		OBASearchResultsListViewController * vc = [[OBASearchResultsListViewController alloc] initWithContext:_appContext searchControllerResult:result];
		[self.navigationController pushViewController:vc animated:TRUE];
        [vc release];
	}
}

@end


#pragma mark OBASearchMapViewController Private Methods

@implementation OBASearchResultsMapViewController (Private)

- (void) loadIcons {

	_stopIcons = [[NSMutableDictionary alloc] init];
	
	NSArray * directionIds = [NSArray arrayWithObjects:@"",@"N",@"NE",@"E",@"SE",@"S",@"SW",@"W",@"NW",nil];
	NSArray * iconTypeIds = [NSArray arrayWithObjects:@"Bus",@"LightRail",@"Rail",@"Ferry",nil];

	for( int j=0; j<[iconTypeIds count]; j++) {
		NSString * iconType = [iconTypeIds objectAtIndex:j];
		for( int i=0; i<[directionIds count]; i++) {		
			NSString * directionId = [directionIds objectAtIndex:i];
			NSString * key = [NSString stringWithFormat:@"%@StopIcon%@",iconType,directionId];
			NSString * imageName = [NSString stringWithFormat:@"%@.png",key];
			UIImage * image = [UIImage imageNamed:imageName];
			[_stopIcons setObject:image forKey:key];
		}		
	}	
	
	_defaultStopIcon = [_stopIcons objectForKey:@"BusStopIcon"];
}

- (void) centerMapOnMostRecentLocation {
	
	OBAModelDAO * modelDao = _appContext.modelDao;
	CLLocation * mostRecentLocation = modelDao.mostRecentLocation;
	
	if( mostRecentLocation ) {
		MKCoordinateRegion region = [self getLocationAsRegion:mostRecentLocation];
		[self setMapRegion:region requestType:OBARegionChangeRequestTypeCurrentLocation];
	}
}

- (void) refreshCurrentLocation {
	
	OBALocationManager * lm = _appContext.locationManager;
	CLLocation * location = lm.currentLocation;

	if( _locationAnnotation ) {
		[_mapView removeAnnotation:_locationAnnotation];
		[_locationAnnotation release];
		_locationAnnotation = nil;
	}
	
	if( location ) {
		_locationAnnotation = [[OBAGenericAnnotation alloc] initWithTitle:nil subtitle:nil coordinate:location.coordinate context:@"currentLocation"];
		[_mapView addAnnotation:_locationAnnotation];
		
		OBALogDebug(@"refreshCurrentLocation: auto center on current location: %d", _autoCenterOnCurrentLocation);
		
		if( _autoCenterOnCurrentLocation ) {
			double radius = MAX(location.horizontalAccuracy,kMinMapRadius);
			MKCoordinateRegion region = [OBASphericalGeometryLibrary createRegionWithCenter:location.coordinate latRadius:radius lonRadius:radius];
			[self setMapRegion:region requestType:OBARegionChangeRequestTypeCurrentLocation];
		}		
	}
}

- (void) setMapRegion:(MKCoordinateRegion)region requestType:(OBARegionChangeRequestType)requestType {

	OBARegionChangeRequest * request = [[OBARegionChangeRequest alloc] initWithRegion:region type:requestType];
	[self setMapRegionWithRequest:request];
	[request release];
}
		 
- (void) setMapRegionWithRequest:(OBARegionChangeRequest*)request {
	
	OBALogDebug(@"setMapRegion: requestType=%d region=%@",request.type,[OBASphericalGeometryLibrary regionAsString:request.region]);
	
	/**
	 * If we are currently in the process of changing the map region, we save the region change request as pending.
	 * Otherwise, we apply the region change.
	 */
	if ( _currentlyChangingRegion ) {
		OBALogDebug(@"saving pending request");
		_pendingRegionChangeRequest = [NSObject releaseOld:_pendingRegionChangeRequest retainNew:request];
	}
	else {
		[_appliedRegionChangeRequests addObject:request];
		[_mapView setRegion:request.region animated:TRUE];
	}
}


- (OBARegionChangeRequest*) getBestRegionChangeRequestForRegion:(MKCoordinateRegion)region {
	
	NSMutableArray * requests = [[NSMutableArray alloc] init];
	OBARegionChangeRequest * bestRequest = nil;
	double bestScore = 0;
	
	NSDate * now = [NSDate date];
	
	for( OBARegionChangeRequest * request in  _appliedRegionChangeRequests ) {
		
		NSTimeInterval interval = [now timeIntervalSinceDate:request.timestamp];

		if( interval <= kRegionChangeRequestsTimeToLive ) {
			[requests addObject:request];
			double score = [request compareRegion:region];
			if( bestRequest == nil || score < bestScore)  {
				bestRequest = request;
				bestScore = score;
			}
		}
	}
	
	_appliedRegionChangeRequests = [NSObject releaseOld:_appliedRegionChangeRequests retainNew:requests];
	
	return bestRequest;
}
- (void) scheduleRefreshOfStopsInRegion:(NSTimeInterval)interval location:(CLLocation*)location {
	
	MKCoordinateRegion region = _mapView.region;
	
	BOOL moreAccurateRegion = _mostRecentLocation != nil && location != nil && location.horizontalAccuracy < _mostRecentLocation.horizontalAccuracy;
	BOOL containedRegion = [OBASphericalGeometryLibrary isRegion:region containedBy:_mostRecentRegion];
	
	OBALogDebug(@"scheduleRefreshOfStopsInRegion: %f %d %d", interval, moreAccurateRegion, containedRegion);
	if( ! moreAccurateRegion && containedRegion )
		return;
	
	_mostRecentLocation = [NSObject releaseOld:_mostRecentLocation retainNew:location];
	
	if( _refreshTimer ) { 
		[_refreshTimer invalidate];
		_refreshTimer = nil;
	}
	
	 _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:interval target:self selector:@selector(refreshStopsInRegion) userInfo:nil repeats:FALSE];	
}
			   
- (NSTimeInterval) getRefreshIntervalForLocationAccuracy:(CLLocation*)location {
	if( location == nil )
		return kStopsInRegionRefreshDelayOnDrag;
	if( location.horizontalAccuracy < 20 )
		return 0;
	if( location.horizontalAccuracy < 200 )
		return 0.25;
	if( location.horizontalAccuracy < 500 )
		return 0.5;
	if( location.horizontalAccuracy < 1000 )
		return 1;
	return 1.5;
}

- (void) refreshStopsInRegion {
	_refreshTimer = nil;
	
	MKCoordinateRegion region = _mapView.region;
	MKCoordinateSpan   span   = region.span;

	if(span.latitudeDelta > kMaxLatDeltaToShowStops) {
		// Reset the most recent region
		CLLocationCoordinate2D p = {0,0};
		_mostRecentRegion = MKCoordinateRegionMake(p, MKCoordinateSpanMake(0,0));
		
		OBANavigationTarget * target = [OBASearchControllerFactory getNavigationTargetForSearchNone];
		[_searchController searchWithTarget:target];
	} else {
		span.latitudeDelta  *= kRegionScaleFactor;
		span.longitudeDelta *= kRegionScaleFactor;
		region.span = span;
	
		_mostRecentRegion = region;
	
		OBANavigationTarget * target = [OBASearchControllerFactory getNavigationTargetForSearchLocationRegion:region];
		[_searchController searchWithTarget:target];
	}
}


- (void) reloadData {
	OBASearchControllerResult * result = _searchController.result;
	_listButton.enabled = (result != nil);
	
	if( result && result.searchType == OBASearchControllerSearchTypeRoute && [result.values count] > 0) {
		[self performSelector:@selector(onListButton:) withObject:self afterDelay:1];
		return;
	}
	
	//[self refreshCurrentLocation];
	[self setAnnotationsFromResults];
	[self setRegionFromResults];
	
	NSString * label = [self computeLabelForCurrentResults];
	self.navigationItem.prompt = label;
	
	[self checkResults];
}

- (UIImage*) getIconForStop:(OBAStopV2*)stop {
	NSString * routeIconType = [self getRouteIconTypeForStop:stop];
	NSString * direction = @"";
	
	if( stop.direction )
		direction = stop.direction;
	
	NSString * key = [NSString stringWithFormat:@"%@StopIcon%@",routeIconType,direction];

	UIImage * image = [_stopIcons objectForKey:key];
	
	if( ! image || [image isEqual:[NSNull null]] )
		return _defaultStopIcon;
	
	return image;
}

- (NSString*) getRouteIconTypeForStop:(OBAStopV2*)stop {
	NSMutableSet * routeTypes = [NSMutableSet set];
	for( OBARouteV2 * route in stop.routes ) {
		if( route.routeType )
			[routeTypes addObject:route.routeType];
	}

	// Heay rail dominations
	if( [routeTypes containsObject:[NSNumber numberWithInt:4]] )
		return @"Ferry";
	else if( [routeTypes containsObject:[NSNumber numberWithInt:2]] )
		return @"Rail";
	else if( [routeTypes containsObject:[NSNumber numberWithInt:0]] )
		return @"LightRail";
	else
		return @"Bus";
}

- (CLLocation*) currentLocation {
	OBALocationManager * lm = _appContext.locationManager;
	CLLocation * location = lm.currentLocation;
	
	if( ! location )
		location = _searchController.searchLocation;

	if( ! location ) {
		CLLocationCoordinate2D center = _mapView.centerCoordinate;	
		location = [[[CLLocation alloc] initWithLatitude:center.latitude longitude:center.longitude] autorelease];	
	}
	
	return location;
}

- (void) setAnnotationsFromResults {
	
	
	NSMutableArray * annotations = [[NSMutableArray alloc] init];
	
	OBASearchControllerResult * result = _searchController.result;
	
	if( result ) {
		[annotations addObjectsFromArray:result.values];

		if( result.searchType == OBASearchControllerSearchTypeAgenciesWithCoverage ) {		   
			for( OBAAgencyWithCoverageV2 * agencyWithCoverage in result.values ) {
				OBAAgencyV2 * agency = agencyWithCoverage.agency;
				OBANavigationTargetAnnotation * an = [[OBANavigationTargetAnnotation alloc] initWithTitle:agency.name subtitle:nil coordinate:agencyWithCoverage.coordinate target:nil];
				[annotations addObject:an];
				[an release];
			}
		}
	}

	NSMutableArray * toAdd = [[NSMutableArray alloc] init];
	NSMutableArray * toRemove = [[NSMutableArray alloc] init];
	
	for( id annotation in _mapAnnotations )  {
		if (! [annotations containsObject:annotation])
			[toRemove addObject:annotation];
	}
	
	for (id annotation in annotations) {
		if( ! [_mapAnnotations containsObject:annotation] )
			[toAdd addObject:annotation];
	}
	
	OBALogDebug(@"Annotations to remove: %d",[toRemove count]);
	OBALogDebug(@"Annotations to add: %d", [toAdd count]);
	
	[_mapView removeAnnotations:toRemove];
	[_mapView addAnnotations:toAdd];
	
	_mapAnnotations = [NSObject releaseOld:_mapAnnotations retainNew:annotations];
	
	[toAdd release];
	[toRemove release];
	[annotations release];
}

- (NSString*) computeLabelForCurrentResults {
	OBASearchControllerResult * result = _searchController.result;
	
	MKCoordinateRegion region = _mapView.region;
	MKCoordinateSpan span = region.span;
	
	NSString * defaultLabel = nil;
	if( span.latitudeDelta > kMaxLatDeltaToShowStops )
		defaultLabel = @"Zoom in to look for stops.";
	
	if( !result )
		return defaultLabel;

	switch( result.searchType ) {
		case OBASearchControllerSearchTypeRoute:
		case OBASearchControllerSearchTypeRouteStops:	
		case OBASearchControllerSearchTypeAddress:
		case OBASearchControllerSearchTypeAgenciesWithCoverage:
		case OBASearchControllerSearchTypeStopId:
			return nil;
            
		case OBASearchControllerSearchTypePlacemark:
		case OBASearchControllerSearchTypeRegion: {
			if( result.outOfRange )
				return @"Out of OneBusAway service area.";
			if( result.limitExceeded )
				return @"Too many stops.  Zoom in for more detail.";
			NSArray * values = result.values;
			if( [values count] == 0 )
				return @"No stops at your current location.";
            return defaultLabel;
		}
            
		case OBASearchControllerSearchTypeNone:			
			return defaultLabel;
	}
    
    return defaultLabel;
}


- (void) setRegionFromResults {
	
	BOOL needsUpdate = FALSE;
	MKCoordinateRegion region = [self computeRegionForCurrentResults:&needsUpdate];
	if( needsUpdate ) {
		OBALogDebug(@"setRegionFromResults");
		[self setMapRegion:region requestType:OBARegionChangeRequestTypeSearchResult];
	}
}


- (MKCoordinateRegion) computeRegionForCurrentResults:(BOOL*)needsUpdate {
	
	*needsUpdate = TRUE;
	
	OBASearchControllerResult * result = _searchController.result;
	
	if( ! result ) {
		OBALocationManager * lm = _appContext.locationManager;
		CLLocation * location = lm.currentLocation;
		if( location && FALSE) {
			// TODO : Figure why this was here
			return [OBASphericalGeometryLibrary createRegionWithCenter:location.coordinate latRadius:kDefaultMapRadius lonRadius:kDefaultMapRadius];
		}
		else {
			*needsUpdate = FALSE;
			return _mapView.region;
		}
	}
	
	switch(result.searchType) {
		case OBASearchControllerSearchTypeStopId:
			return [self computeRegionForNClosestStops:result.values center:[self currentLocation] numberOfStops:kShowNClosestStops];
		case OBASearchControllerSearchTypeRoute:
		case OBASearchControllerSearchTypeRouteStops:	
			return [self computeRegionForNearbyStops:result.values];
		case OBASearchControllerSearchTypePlacemark:
			return [self computeRegionForPlacemarks:result.additionalValues andStops:result.values];
		case OBASearchControllerSearchTypeAddress:
			return [self computeRegionForPlacemarks:result.values];
		case OBASearchControllerSearchTypeAgenciesWithCoverage:
			return [self computeRegionForAgenciesWithCoverage:result.values];
		case OBASearchControllerSearchTypeNone:
		case OBASearchControllerSearchTypeRegion:
		default:
			*needsUpdate = FALSE;
			return _mapView.region;
	}
}

- (MKCoordinateRegion) computeRegionForStops:(NSArray*)stops {
    
    double latRun = 0.0, lonRun = 0.0;
    int    stopCount = 0;
    
	for( OBAStop * stop in stops ) {
        latRun += stop.lat;
        lonRun += stop.lon;
        ++stopCount;
	}

    CLLocation * centerLocation = nil;
    
    if (stopCount == 0) {
        centerLocation = self.currentLocation;
    } else {
        CLLocationCoordinate2D center;
        center.latitude  = latRun / stopCount;
        center.longitude = lonRun / stopCount;
        
        centerLocation = [[CLLocation alloc] initWithLatitude:center.latitude longitude:center.longitude];
        [centerLocation autorelease];
    }
    
	return [self computeRegionForStops:stops center:centerLocation];
}

NSInteger sortStopsByDistanceFromLocation(id o1, id o2, void *context) {
	
	OBAStop * stop1 = (OBAStop*) o1;
	OBAStop * stop2 = (OBAStop*) o2;
	CLLocation * location = (CLLocation*)context;
	
	CLLocation * stopLocation1 = [[CLLocation alloc] initWithLatitude:stop1.lat longitude:stop1.lon];
	CLLocation * stopLocation2 = [[CLLocation alloc] initWithLatitude:stop2.lat longitude:stop2.lon];
	
	double v1 = [location distanceFromLocation:stopLocation1];
	double v2 = [location distanceFromLocation:stopLocation2];
	
	[stopLocation1 release];
	[stopLocation2 release];
	
    if (v1 < v2)
        return NSOrderedAscending;
    else if (v1 > v2)
        return NSOrderedDescending;
    else
        return NSOrderedSame;
}

- (MKCoordinateRegion) computeRegionForNClosestStops:(NSArray*)stops center:(CLLocation*)location numberOfStops:(NSUInteger)numberOfStops {
	NSMutableArray * stopsSortedByDistance = [NSMutableArray arrayWithArray:stops];
	[stopsSortedByDistance sortUsingFunction:sortStopsByDistanceFromLocation context:location];
	while( [stopsSortedByDistance count] > numberOfStops )
		[stopsSortedByDistance removeLastObject];
	return [self computeRegionForStops:stopsSortedByDistance center:location];
}

- (MKCoordinateRegion) computeRegionForStops:(NSArray*)stops center:(CLLocation*)location {
	
	CLLocationCoordinate2D center = location.coordinate;
	
	MKCoordinateRegion region = [OBASphericalGeometryLibrary createRegionWithCenter:center latRadius:kDefaultMapRadius lonRadius:kDefaultMapRadius];
	MKCoordinateSpan span = region.span;
	
	for( OBAStop * stop in stops ) {
		double latDelta = ABS(stop.lat - center.latitude) * 2.0 * kPaddingScaleFactor;
		double lonDelta = ABS(stop.lon - center.longitude) * 2.0 * kPaddingScaleFactor;
		span.latitudeDelta =  MAX(span.latitudeDelta,latDelta);
		span.longitudeDelta =  MAX(span.longitudeDelta,lonDelta);
	}
	
	region.center = center;
	region.span = span;
	
	return region;
}

- (MKCoordinateRegion) computeRegionForNearbyStops:(NSArray*)stops {
	
	NSMutableArray * stopsInRange = [NSMutableArray array];
	CLLocation * center = [self currentLocation];
	
	for( OBAStop * stop in stops) {
		CLLocation * location = [[CLLocation alloc] initWithLatitude:stop.lat longitude:stop.lon];
		double d = [location distanceFromLocation:center];
		if( d < kMaxMapDistanceFromCurrentLocation )
			[stopsInRange addObject:stop];
		[location release];
	}
	
	if( [stopsInRange count] > 0)
		return [self computeRegionForStops:stopsInRange];
	else
		return [self computeRegionForStops:stops];
}

- (MKCoordinateRegion) computeRegionForPlacemarks:(NSArray*)placemarks {
	
	OBACoordinateBounds * bounds = [OBACoordinateBounds bounds];
	
	for( OBAPlacemark * placemark in placemarks )
		[bounds addCoordinate:placemark.coordinate];
	
	if( bounds.empty )
		return _mapView.region;
	
	return bounds.region;
}

- (MKCoordinateRegion) computeRegionForPlacemarks:(NSArray*)placemarks andStops:(NSArray*)stops {
	
	CLLocation * center = [self currentLocation];
	
	for( OBAPlacemark * placemark in placemarks ) {
		CLLocationCoordinate2D coordinate = placemark.coordinate;
		center = [[[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude] autorelease];
	}
	
	return [self computeRegionForNClosestStops:stops center:center numberOfStops:kShowNClosestStops];
}

- (MKCoordinateRegion) computeRegionForAgenciesWithCoverage:(NSArray*)agenciesWithCoverage {
	if( [agenciesWithCoverage count] == 0 )
		return _mapView.region;
	
	OBACoordinateBounds * bounds = [OBACoordinateBounds bounds];
	
	for( OBAAgencyWithCoverage * agencyWithCoverage in agenciesWithCoverage )
		[bounds addCoordinate:agencyWithCoverage.coordinate];
	
	if( bounds.empty )
		return _mapView.region;
	
	MKCoordinateRegion region = bounds.region;
	
	MKCoordinateRegion minRegion = [OBASphericalGeometryLibrary createRegionWithCenter:region.center latRadius:50000 lonRadius:50000];
	
	if( region.span.latitudeDelta < minRegion.span.latitudeDelta )
		region.span.latitudeDelta = minRegion.span.latitudeDelta;
	
	if( region.span.longitudeDelta < minRegion.span.longitudeDelta )
		region.span.longitudeDelta = minRegion.span.longitudeDelta;
	
	return region;
}

- (MKCoordinateRegion) getLocationAsRegion:(CLLocation*)location {
	if( ! location ) {
		
	}
	
	/*
	if( location.horizontalAccuracy == 0 ) {
		CLLocationCoordinate2D defaultCenter = {0,0};
		return MKCoordinateRegionMake(defaultCenter,MKCoordinateSpanMake(180, 180));
	}
	*/
	
	double radius = MAX(location.horizontalAccuracy,kMinMapRadius);
	MKCoordinateRegion region = [OBASphericalGeometryLibrary createRegionWithCenter:location.coordinate latRadius:radius lonRadius:radius];	
	region = [_mapView regionThatFits:region];
	return region;
}

- (void) checkResults {
	
	OBASearchControllerResult * result = _searchController.result;
	if( ! result )
		return;
	
	switch (result.searchType) {
		case OBASearchControllerSearchTypeRoute:
			[self checkNoRouteResults];
			break;
		case OBASearchControllerSearchTypeAddress:
			[self checkNoPlacemarksResults];
			break;
		default:
			break;
	}
}

- (void) checkNoRouteResults {
	OBASearchControllerResult * result = _searchController.result;
	if( [result.values count] == 0 ) {
		[self showNoResultsAlertWithTitle: @"No routes found" prompt:@"No routes were found for your search."];
	}
}

- (void) checkNoPlacemarksResults {
	OBASearchControllerResult * result = _searchController.result;
	if( [result.values count] == 0 ) {
		_listButton.enabled = FALSE;
		[self showNoResultsAlertWithTitle: @"No places found" prompt:@"No places were found for your search."];
	}
}

- (void) showNoResultsAlertWithTitle:(NSString*)title prompt:(NSString*)prompt {

	_listButton.enabled = FALSE;
	
	if( ! [self controllerIsVisibleAndActive] )
		return;
	
	UIAlertView * view = [[UIAlertView alloc] init];
	view.title = title;
	view.message = [NSString stringWithFormat:@"%@ See the list of supported transit agencies.",prompt];
	view.delegate = self;
	[view addButtonWithTitle:@"Agencies"];
	[view addButtonWithTitle:@"Dismiss"];
	view.cancelButtonIndex = 1;
	[view show];
}

- (BOOL) controllerIsVisibleAndActive {
	
	// Ignore errors if our app isn't currently active
	if( ! _appContext.active )
		return FALSE;
	
	// Ignore errors if our view isn't currently on top
	UINavigationController * nav = self.navigationController;
	if( self != [nav visibleViewController])
		return FALSE;
	
	return TRUE;
}	

@end

@implementation OBARegionChangeRequest

@synthesize type = _type;
@synthesize region = _region;
@synthesize timestamp = _timestamp;

- (id) initWithRegion:(MKCoordinateRegion)region type:(OBARegionChangeRequestType)type {
	
	if( self = [super init] ) {
		_region = region;
		_type = type;
		_timestamp = [[NSDate alloc] init];
	}
	return self;
}

-(void) dealloc {
	[_timestamp release];
	[super dealloc];
}

- (double) compareRegion:(MKCoordinateRegion)region {
	return [OBASphericalGeometryLibrary getDistanceFromRegion:_region toRegion:region];
}

@end



// Private CoreGraphics API. Apple does not document CGVirtualDisplay; it can change
// or disappear in a future macOS. The same interface is used by Telas and DeskPad.
// See THIRD_PARTY_NOTICES for the Telas license and copyright notice.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((weak_import))
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(copy, nonatomic) void (^terminationHandler)(id _Nullable, id _Nullable);
@end

__attribute__((weak_import))
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate NS_SWIFT_NAME(init(width:height:refreshRate:));
@end

__attribute__((weak_import))
@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
@end

__attribute__((weak_import))
@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor NS_SWIFT_NAME(init(descriptor:));
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings NS_SWIFT_NAME(applySettings(_:));
@property(readonly, nonatomic) unsigned int displayID;
@end

/// Sets sRGB primaries only when this macOS build actually implements the setters.
static inline void CGVirtualDisplayDescriptorApplyStandardPrimaries(CGVirtualDisplayDescriptor *descriptor) {
    if (![descriptor respondsToSelector:@selector(setRedPrimary:)] ||
        ![descriptor respondsToSelector:@selector(setGreenPrimary:)] ||
        ![descriptor respondsToSelector:@selector(setBluePrimary:)] ||
        ![descriptor respondsToSelector:@selector(setWhitePoint:)]) {
        return;
    }
    descriptor.redPrimary = CGPointMake(0.6400, 0.3300);
    descriptor.greenPrimary = CGPointMake(0.3000, 0.6000);
    descriptor.bluePrimary = CGPointMake(0.1500, 0.0600);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
}

NS_ASSUME_NONNULL_END

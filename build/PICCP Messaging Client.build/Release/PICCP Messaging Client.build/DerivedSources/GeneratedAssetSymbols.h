#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "Rhombus" asset catalog image resource.
static NSString * const ACImageNameRhombus AC_SWIFT_PRIVATE = @"Rhombus";

#undef AC_SWIFT_PRIVATE

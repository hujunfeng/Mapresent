//
//  DSMRTimelineView.m
//  Mapresent
//
//  Created by Justin Miller on 1/24/12.
//  Copyright (c) 2012 Development Seed. All rights reserved.
//

#import "DSMRTimelineView.h"

@implementation DSMRTimelineView

- (id)initWithCoder:(NSCoder *)decoder
{
    self = [super initWithCoder:decoder];

    if (self)
        [self setFrame:CGRectMake([self frame].origin.x, [self frame].origin.y, 3072, [self frame].size.height)];
    
    return self;
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef c = UIGraphicsGetCurrentContext();

    CGContextSetFillColorWithColor(c, [[UIColor darkGrayColor] CGColor]);
    CGContextFillRect(c, rect);

    CGContextSetFillColorWithColor(c, [[UIColor colorWithWhite:0.0 alpha:0.5] CGColor]);
    CGContextFillRect(c, CGRectMake(0, 0, 512.0, 250.0));
    CGContextFillRect(c, CGRectMake(self.bounds.size.width - 512.0, 0, 512.0, 250.0));

    CGContextSetStrokeColorWithColor(c, [[UIColor colorWithWhite:1.0 alpha:0.25] CGColor]);
    CGContextSetFillColorWithColor(c, [[UIColor colorWithWhite:1.0 alpha:0.25] CGColor]);

    CGContextSetLineWidth(c, 2);
    
    for (float i = 512.0; i < self.bounds.size.width - 512.0; i = i + 8.0)
    {
        CGContextBeginPath(c);
        
        float y;
        
        if (fmodf(i, 64.0) == 0.0)
        {
            [[NSString stringWithFormat:@"%i", (int)(i - 512.0) / 64] drawAtPoint:CGPointMake(i + 4.0, 65.0) withFont:[UIFont systemFontOfSize:[UIFont smallSystemFontSize]]];

            y = 75.0;
        }
        else
        {
            y = 50.0;
        }
        
        CGContextMoveToPoint(c, i, 0.0);
        CGContextAddLineToPoint(c, i, y);
        
        CGContextStrokePath(c);
    }
    
    CGContextSetLineWidth(c, 2.0);
    CGContextBeginPath(c);    
    CGContextMoveToPoint(c, self.bounds.size.width - 512.0, 0.0);
    CGContextAddLineToPoint(c, self.bounds.size.width - 512.0, 75.0);
    CGContextStrokePath(c);
}

@end
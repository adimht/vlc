/*
 *     Generated by class-dump 3.1.1.
 *
 *     class-dump is Copyright (C) 1997-1998, 2000-2001, 2004-2006 by Steve Nygard.
 */

#import <BackRow/BRControl.h>

#import "BRTextContainerProtocol.h"

@class BRIPv4AddressSelectionLayer, BRTextLayer;

@interface BRIPv4AddressEntryControl : BRControl <BRTextContainer>
{
    BRIPv4AddressSelectionLayer *_addressPicker;
    BRTextLayer *_labelLayer;
    struct CGSize _addressPickerSize;
    float _labelPadding;
    id <BRTextEntryDelegate> _textEntryDelegate;
}

- (id)init;
- (void)dealloc;
- (struct CGSize)preferredSizeFromScreenSize:(struct CGSize)fp8;
- (void)setDelegate:(id)fp8;
- (void)setLabel:(id)fp8;
- (void)setInitialAddress:(id)fp8;
- (void)reset;
- (void)setFrame:(struct CGRect)fp8;
- (BOOL)brEventAction:(id)fp8;
- (id)stringValue;

@end


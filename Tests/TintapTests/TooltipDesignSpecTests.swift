import Testing
@testable import Tintap

struct TooltipDesignSpecTests {
    @Test
    func figmaStateSizesArePreserved() {
        #expect(TooltipDesignSpec.compactSize.width == 162)
        #expect(TooltipDesignSpec.compactSize.height == 42)
        #expect(TooltipDesignSpec.progressSize.width == 254)
        #expect(TooltipDesignSpec.progressSize.height == 97)
        #expect(TooltipDesignSpec.compactButtonSize.width == 56)
        #expect(TooltipDesignSpec.compactButtonSize.height == 23)
        #expect(TooltipDesignSpec.borderWidth == 1)
        #expect(!TooltipDesignSpec.usesSystemWindowShadow)
        #expect(TooltipDesignSpec.resultSize(forContentHeight: 93).width == 400)
        #expect(TooltipDesignSpec.resultSize(forContentHeight: 93).height == 205)
    }

    @Test
    func resultContentCapsAtFigmaMaximum() {
        #expect(TooltipDesignSpec.resultSize(forContentHeight: 240).height == 353)
        #expect(TooltipDesignSpec.resultSize(forContentHeight: 800).height == 353)
        #expect(TooltipDesignSpec.resultMaximumContentHeight == 240)
    }
}

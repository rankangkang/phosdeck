import XCTest
@testable import Phosdeck

final class FocusStackRegressionTests: XCTestCase {
    func testClippedFocusResponseSuppressesNeighbourhoodBeforeDepthSolve() throws {
        var focus = LumaImage(width:9,height:9,pixels:.init(repeating:1,count:81))
        var peak = MergePlane(width:9,height:9,values:.init(repeating:0.2,count:81))
        peak.values[4*9+4] = 1

        try MergeFusionPlan.ignoreClippedFocus(&focus,clipPlane:peak,clip:1,radius:2)

        XCTAssertEqual(focus.pixels[4*9+4],0)
        XCTAssertEqual(focus.pixels[2*9+2],0)
        XCTAssertEqual(focus.pixels[6*9+6],0)
        XCTAssertEqual(focus.pixels[1*9+4],1)
        XCTAssertEqual(focus.pixels[4*9+1],1)
    }

    func testSubClipFocusResponseRemainsAvailable() throws {
        var focus = LumaImage(width:5,height:5,pixels:.init(repeating:1,count:25))
        var peak = MergePlane(width:5,height:5,values:.init(repeating:0.2,count:25))
        peak.values[2*5+2] = 0.899

        try MergeFusionPlan.ignoreClippedFocus(&focus,clipPlane:peak,clip:1,radius:2)

        XCTAssertTrue(focus.pixels.allSatisfy { $0 == 1 })
    }

    func testClippedSpecularResponseCannotSelectTheWrongDepthPlane() throws {
        let w = 48,h = 48
        var specular = LumaImage(width:w,height:h,pixels:.init(repeating:0.01,count:w*h))
        var green = MergePlane(width:w,height:h,values:.init(repeating:0.2,count:w*h))
        var focused = [Float](repeating:0.02,count:w*h)
        let guide = LumaImage(width:w,height:h,pixels:.init(repeating:0.4,count:w*h))
        for y in 16..<32 { for x in 16..<32 {
            specular.pixels[y*w+x] = 8;green.values[y*w+x] = 1;focused[y*w+x] = 0.5
        } }
        let before = try StackDepthSolver.solve(volume:[specular.pixels,focused],lumas:[guide,guide])
        try MergeFusionPlan.ignoreClippedFocus(&specular,clipPlane:green,clip:1,radius:2)
        let after = try StackDepthSolver.solve(volume:[specular.pixels,focused],lumas:[guide,guide])
        XCTAssertLessThan(before.depth[24*w+24],0.2)
        XCTAssertGreaterThan(after.depth[24*w+24],0.8)
    }
}

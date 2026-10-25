import XCTest
import UIKit
@testable import StencilLocalAI

final class LocalAIImageTests: XCTestCase {
    func image(width: Int,height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size:CGSize(width:width,height:height),format:format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x:0,y:0,width:width,height:height))
            UIColor.black.setFill(); ctx.fill(CGRect(x:0,y:0,width:width/2,height:height/2))
        }
    }
    func testPaddingIsRemovedWithoutChangingSourceAspectOrOrientation() throws {
        let input = try LocalAIImages.prepare(XCTUnwrap(image(width:80,height:120).pngData()))
        XCTAssertEqual(input.canvasWidth,128)
        XCTAssertEqual(input.canvasHeight,128)
        XCTAssertEqual(input.contentRect,CGRect(x:24,y:4,width:80,height:120))
        let canvas = try XCTUnwrap(UIImage(data:input.png)?.cgImage)
        let output = try LocalAIImages.binary(canvas,crop:input.contentRect)
        XCTAssertEqual(output.width,80); XCTAssertEqual(output.height,120)
        let bytes = try XCTUnwrap(output.dataProvider?.data) as Data
        XCTAssertEqual(bytes[20*output.bytesPerRow+20],0)
        XCTAssertEqual(bytes[100*output.bytesPerRow+60],255)
        XCTAssertEqual(Set(bytes),[0,255])
    }
    func testLargeImageIsBoundedAndInvalidDataRejected() throws {
        let input = try LocalAIImages.prepare(XCTUnwrap(image(width:1600,height:2400).jpegData(compressionQuality:0.9)))
        XCTAssertLessThanOrEqual(input.reference.height,768)
        XCTAssertEqual(input.canvasWidth%64,0); XCTAssertEqual(input.canvasHeight%64,0)
        XCTAssertThrowsError(try LocalAIImages.prepare(Data("not an image".utf8)))
    }
}

import CoreGraphics
import QuartzCore
import MetalKit
import ARKit
import Photos

class MetalManager {
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let defaultLibrary: MTLLibrary
  private let updateEnvironmentMapFunction: MTLFunction
  private let pipelineState: MTLComputePipelineState
  private let threadGroupsCount = MTLSizeMake(16, 32, 1)
  private let threadGroups: MTLSize

  private let textureLoader: MTKTextureLoader

  private let ciContext: CIContext

  init?(withMapHeight height: Int) {
    let width = height * 2
    threadGroups = MTLSizeMake(width / threadGroupsCount.width, height / threadGroupsCount.height, 1)
    if
      let d = MTLCreateSystemDefaultDevice(),
      let queue = d.makeCommandQueue(),
      let library = try? d.makeDefaultLibrary(bundle: Bundle(for: MetalManager.self)),
      let function = library.makeFunction(name: "updateEnvironmentMap"),
      let state = try? d.makeComputePipelineState(function: function)
    {
      device = d
      commandQueue = queue
      defaultLibrary = library
      updateEnvironmentMapFunction = function
      pipelineState = state
      ciContext = CIContext(mtlDevice: device)
      textureLoader = MTKTextureLoader(device: device)
    } else {
      print("This device does not support the Metal framework.")
      return nil
    }
  }

  func newReadableTexture(fromCVPixelBuffer pixelBuffer: CVPixelBuffer) -> MTLTexture? {
    let cgImage = convertToCGImage(from: pixelBuffer)
    if let image = cgImage {
      return try? textureLoader.newTexture(cgImage: image, options: nil)
    } else {
      return nil
    }
  }

  func newReadableTexture(fromCGImage cgImage: CGImage) -> MTLTexture? {
    let textureAsImage = UIImagePNGRepresentation(UIImage(cgImage: cgImage))
    return try? textureLoader.newTexture(data: textureAsImage!, options: nil)
  }

  func newWritableTexture(fromCGImage cgImage: CGImage) -> MTLTexture? {
    return try? textureLoader.newTexture(cgImage: cgImage,
                                         options: [MTKTextureLoader.Option.textureUsage: MTLTextureUsage.shaderWrite.rawValue,
                                                   MTKTextureLoader.Option.textureStorageMode: MTLStorageMode.shared.rawValue])
  }

  func newWritableTexture(withHeight height: Int, withColor color: UIColor) -> MTLTexture? {
    let width = height * 2
    let cgContext = CGContext(data: nil,
                              width: width,
                              height: height,
                              bitsPerComponent: RGBA32.bitsPerComponent,
                              bytesPerRow: RGBA32.bytesPerRow(width: width),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: RGBA32.bitmapInfo)
    guard let context = cgContext else {
      fatalError("Could not create texture")
    }
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = context.makeImage()
    if let image = cgImage {
      return newWritableTexture(fromCGImage: image)
    } else {
      print("Could not convert image to MTLTexture")
      return nil
    }
  }

  func updateEnvironmentMapTask(currentFrame currentFrameTexture: MTLTexture,
                                convertingCoordinatesWith coordinateConversionTexture: MTLTexture,
                                environmentMap environmentMapTexture: MTLTexture,
                                info frameInfo: UnsafeRawPointer) {
    guard
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
        return
    }

    commandEncoder.setComputePipelineState(pipelineState)

    commandEncoder.setTexture(currentFrameTexture, index: 0)
    commandEncoder.setTexture(coordinateConversionTexture, index: 1)
    commandEncoder.setTexture(environmentMapTexture, index: 2)

    let frameInfoBuffer = device.makeBuffer(bytes: frameInfo, length: MemoryLayout<FrameInfo>.size, options: MTLResourceOptions.storageModeShared)
    commandEncoder.setBuffer(frameInfoBuffer, offset: 0, index: 0)

    commandEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupsCount)

    commandEncoder.endEncoding()

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
  }

  private func convertToCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let cgImage = ciContext.createCGImage(ciImage, from: CGRect(x: 0,
                                                                y: 0,
                                                                width: CVPixelBufferGetWidth(pixelBuffer),
                                                                height: CVPixelBufferGetHeight(pixelBuffer)))
    return cgImage
  }

  // TODO: Fix this method
  func image(fromTexture texture: MTLTexture) -> CGImage? {
    guard texture.pixelFormat == .bgra8Unorm_srgb else {
      return nil
    }

    let imageByteCount = texture.width * texture.height * 4
    let bytesPerRow = texture.width * 4
    let imageBytes = UnsafeMutableRawPointer.allocate(bytes: imageByteCount, alignedTo: 4)
    let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
    texture.getBytes(imageBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

    let context = CGContext(data: imageBytes,
                            width: texture.width,
                            height: texture.height,
                            bitsPerComponent: RGBA32.bitsPerComponent,
                            bytesPerRow: RGBA32.bytesPerRow(width: texture.width),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
    let image = context?.makeImage()
    imageBytes.deallocate(bytes: imageByteCount, alignedTo: 4)
    return image
  }

}

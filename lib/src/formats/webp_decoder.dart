part of image;

/**
 * Decode a WebP formatted image. This supports lossless (vp8l), lossy (vp8),
 * lossy+alpha, and animated WebP images.
 */
class WebPDecoder {
  WebPInfo webp;

  /**
   * Validate the file is a WebP image and get information about it.
   * If the file is not a valid WebP image, null is returned.
   */
  WebPInfo getInfo(List<int> bytes) {
    // WebP is stored in little-endian byte order.
    _input = new Arc.InputStream(bytes);

    if (!_getHeader(_input)) {
      return null;
    }

    webp = new WebPInfo();
    if (!_getInfo(_input, webp)) {
      return null;
    }

    switch (webp.format) {
      case WebPInfo.FORMAT_ANIMATED:
        return webp;
      case WebPInfo.FORMAT_LOSSLESS:
        _input.position = webp._vp8Position;
        VP8L vp8l = new VP8L(_input, webp);
        if (!vp8l.decodeHeader()) {
          return null;
        }
        return webp;
      case WebPInfo.FORMAT_LOSSY:
        _input.position = webp._vp8Position;
        VP8 vp8 = new VP8(_input, webp);
        if (!vp8.decodeHeader()) {
          return null;
        }
        return webp;
    }

    return null;
  }

  Image decodeFrame(int frame) {
    if (_input == null || webp == null) {
      return null;
    }

    if (frame >= webp.frames.length || frame < 0) {
      return null;
    }

    if (webp.hasAnimation) {
      WebPFrame f = webp.frames[frame];
      Arc.InputStream frameData = _input.subset(f._framePosition,
          f._frameSize);

      return _decodeFrame(frameData, frame: frame);
    }

    if (webp.format == WebPInfo.FORMAT_LOSSLESS) {
      Arc.InputStream data = _input.subset(webp._vp8Position, webp._vp8Size);
      return new VP8L(data, webp).decode();
    } else if (webp.format == WebPInfo.FORMAT_LOSSY) {
      Arc.InputStream data = _input.subset(webp._vp8Position, webp._vp8Size);
      return new VP8(data, webp).decode();
    }

    return null;
  }

  /**
   * Decode a WebP formatted file stored in [bytes] into an Image.
   * If it's not a valid webp file, null is returned.
   * If the webp file stores animated frames, only the first image will
   * be returned.  Use [decodeAnimation] to decode the full animation.
   */
  Image decodeImage(List<int> bytes, {int frame: 0}) {
    // WebP is stored in little-endian byte order.
    Arc.InputStream input = new Arc.InputStream(bytes);
    if (!_getHeader(input)) {
      return null;
    }

    return _decodeFrame(input, frame: frame);
  }

  /**
   * Decode all of the frames of an animated webp. For single image webps,
   * this will return an animation with a single frame.
   */
  Animation decodeAnimation(List<int> bytes) {
    if (getInfo(bytes) == null) {
      return null;
    }

    Animation anim = new Animation();
    anim.loopCount = webp.animLoopCount;

    if (webp.hasAnimation) {
      Image lastImage = new Image(webp.width, webp.height);
      for (int i = 0; i < webp.numFrames; ++i) {
        if (lastImage == null) {
          lastImage = new Image(webp.width, webp.height);
        } else {
          lastImage = new Image.from(lastImage);
        }

        WebPFrame frame = webp.frames[i];
        Image image = decodeFrame(i);
        if (image == null) {
          return null;
        }

        if (lastImage != null) {
          if (frame.clearFrame) {
            lastImage.fill(webp.animBackgroundColor);
          }
          copyInto(lastImage, image, dstX: frame.x, dstY: frame.y);
        } else {
          lastImage = image;
        }

        anim.addFrame(lastImage, frame.duration);
      }
    } else {
      Image image = decodeFrame(0);
      if (image == null) {
        return null;
      }

      anim.addFrame(image);
    }

    return anim;
  }


  Image _decodeFrame(Arc.InputStream input, {int frame: 0}) {
    WebPInfo webp = new WebPInfo();
    if (!_getInfo(input, webp)) {
      return null;
    }

    if (webp.format == 0) {
      return null;
    }

    if (webp.hasAnimation) {
      if (frame >= webp.frames.length || frame < 0) {
        return null;
      }
      WebPFrame f = webp.frames[frame];
      Arc.InputStream frameData = input.subset(f._framePosition,
                                               f._frameSize);

      return _decodeFrame(frameData, frame: frame);
    } else {
      Arc.InputStream data = input.subset(webp._vp8Position, webp._vp8Size);
      if (webp.format == WebPInfo.FORMAT_LOSSLESS) {
        return new VP8L(data, webp).decode();
      } else if (webp.format == WebPInfo.FORMAT_LOSSY) {
        return new VP8(data, webp).decode();
      }
    }

    return null;
  }

  bool _getHeader(Arc.InputStream input) {
    // Validate the webp format header
    String tag = input.readString(4);
    if (tag != 'RIFF') {
      return false;
    }

    int fileSize = input.readUint32();

    tag = input.readString(4);
    if (tag != 'WEBP') {
      return false;
    }

    return true;
  }

  bool _getInfo(Arc.InputStream input, WebPInfo webp) {
    bool found = false;
    while (!input.isEOS && !found) {
      String tag = input.readString(4);
      int size = input.readUint32();
      // For odd sized chunks, there's a 1 byte padding at the end.
      int diskSize = ((size + 1) >> 1) << 1;
      int p = input.position;

      switch (tag) {
        case 'VP8X':
          if (!_getVp8xInfo(input, webp)) {
            return false;
          }
          break;
        case 'VP8 ':
          webp._vp8Position = input.position;
          webp._vp8Size = size;
          webp.format = WebPInfo.FORMAT_LOSSY;
          found = true;
          break;
        case 'VP8L':
          webp._vp8Position = input.position;
          webp._vp8Size = size;
          webp.format = WebPInfo.FORMAT_LOSSLESS;
          found = true;
          break;
        case 'ALPH':
          webp._alphaData = new Arc.InputStream(input.buffer,
              byteOrder: input.byteOrder);
          webp._alphaData.position = input.position;
          webp._alphaSize = size;
          input.skip(diskSize);
          break;
        case 'ANIM':
          webp.format = WebPInfo.FORMAT_ANIMATED;
          if (!_getAnimInfo(input, webp)) {
            return false;
          }
          break;
        case 'ANMF':
          if (!_getAnimFrameInfo(input, webp, size)) {
            return false;
          }
          break;
        case 'ICCP':
          webp.iccp = input.readString(size);
          break;
        case 'EXIF':
          webp.exif = input.readString(size);
          break;
        case 'XMP ':
          webp.xmp = input.readString(size);
          break;
        default:
          print('UNKNOWN WEBP TAG: $tag');
          input.skip(diskSize);
          break;
      }

      int remainder = diskSize - (input.position - p);
      if (remainder > 0) {
        input.skip(remainder);
      }
    }

    /**
     * The alpha flag might not have been set, but it does in fact have alpha
     * if there is an ALPH chunk.
     */
    if (!webp.hasAlpha) {
      webp.hasAlpha = webp._alphaData != null;
    }

    return webp.format != 0;
  }

  bool _getVp8xInfo(Arc.InputStream input, WebPInfo webp) {
    if (input.readBits(2) != 0) {
      return false;
    }
    int icc = input.readBits(1);
    int alpha = input.readBits(1);
    int exif = input.readBits(1);
    int xmp = input.readBits(1);
    int a = input.readBits(1);
    if (input.readBits(1) != 0) {
      return false;
    }
    if (input.readUint24() != 0) {
      return false;
    }
    int w = input.readUint24() + 1;
    int h = input.readUint24() + 1;

    webp.width = w;
    webp.height = h;
    webp.hasAnimation = a != 0;
    webp.hasAlpha = alpha != 0;

    return true;
  }

  bool _getAnimInfo(Arc.InputStream input, WebPInfo webp) {
    int c = input.readUint32();
    webp.animLoopCount = input.readUint16();

    // Color is stored in blue,green,red,alpha order.
    int a = getRed(c);
    int r = getGreen(c);
    int g = getBlue(c);
    int b = getAlpha(c);
    webp.animBackgroundColor = getColor(r, g, b, a);
    return true;
  }

  bool _getAnimFrameInfo(Arc.InputStream input, WebPInfo webp, int size) {
    WebPFrame frame = new WebPFrame(input, size);
    if (!frame.isValid) {
      return false;
    }
    webp.frames.add(frame);
    return true;
  }

  Arc.InputStream _input;
}
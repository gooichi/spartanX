//
//  SXConnectionSocket.swift
//  spartanX
//
//  Created by yuuji on 9/11/16.
//
//

import Foundation
import CKit
import swiftTLS

public struct SXConnectionSocket: ConnectionSocket
{

    static let defaultBufsize = 5242880
    public var sockfd: Int32
    public var domain: SXSocketDomains
    public var type: SXSocketTypes
    public var `protocol`: Int32
    public var port: in_port_t?
    var tlsContext: TLSClient?
    
    public var address: SXSocketAddress?
    public var readBufsize: size_t
    
    var handler: ((Data?) -> Bool)?
    public var manager: SXKernelManager?
    
    public var errhandler: ((Error) -> Bool)?
}

//MARK: - runtime
extension SXConnectionSocket: KqueueManagable {
    
    @inline(__always)
    public func write(data: Data) throws {
        if let tlsc = tlsContext {
            _ = try tlsc.write(data: data)
        } else {
            if send(sockfd, data.bytes, data.length, 0) == -1 {
                throw SXSocketError.send("send: \(String.errno)")
            }
        }
    }
    
    public static func oneshot(tls: Bool, hostname: String, service: String, request: Data, expectedResponseSize size: Int = SXConnectionSocket.defaultBufsize, callback: (Data?) -> () ) throws {
        let socket = try SXConnectionSocket(tls: tls, hostname: hostname, service: service, bufsize: size)
        try socket.write(data: request)
        let data = try socket.read()
        callback(data)
        socket.done()
    }
    
    public func read() throws -> Data? {
        return try read(bufsize: self.readBufsize)
    }
    
    @inline(__always)
    public func read(bufsize size: Int) throws -> Data? {
        
        if let tlsc = tlsContext {
            return try? tlsc.read(size: size)
        } else {
            
            var buffer = [UInt8](repeating: 0, count: size)
            let flags: Int32 = 0
            
            let len = recv(sockfd, &buffer, size, flags)
            
            if len == 0 {
                return nil
            }
            
            if len == -1 {
                throw SXSocketError.recv(String.errno)
            }
            
            return Data(bytes: buffer, count: len)
        }
    }
    
    public func runloop(kdata: Int, udata: UnsafeRawPointer!) {
        do {
            let payload = try self.read(bufsize: kdata)
            if handler?(payload) == false {
                done()
            }
        } catch {
            if let errh = errhandler {
                if !errh(error) {
                    done()
                }
            } else {
                done()
            }
        }
    }
    
    public func done() {
        if var manager = self.manager {
            manager.unregister(for: self.ident)
        }
        close(self.sockfd)
    }
}

//MARK: - initializers
public extension SXConnectionSocket {
    public init(tls: Bool = false, hostname: String, service: String, type: SXSocketTypes = .stream, `protocol`: Int32 = 0, bufsize: Int = SXConnectionSocket.defaultBufsize) throws {
        let addresses: [SXSocketAddress] = try! SXSocketAddress.DNSLookup(hostname: hostname, service: service)
        var fd: Int32 = -1
        self.type = type
        self.domain = .unspec
        self.`protocol` = `protocol`
        self.readBufsize = bufsize
        
        searchAddress: for address in addresses {
            switch address {
            case var .inet(addr):
                fd = socket(AF_INET, type.rawValue, 0)
                if Foundation.connect(fd, pointer(of: &addr).cast(to: sockaddr.self), address.socklen) == -1 {
                    continue
                }
                self.domain = .inet
                break searchAddress
            case var .inet6(addr):
                fd = socket(AF_INET6, type.rawValue, 0)
                if Foundation.connect(fd, pointer(of: &addr).cast(to: sockaddr.self), address.socklen) == -1 {
                    continue
                }
                self.domain = .inet6
                break searchAddress
            default:
                throw SXSocketError.unconnectable
            }
        }
        
        if fd == -1 {
            throw SXSocketError.connect(String.errno)
        }
        
        self.sockfd = fd
        
        if tls {
            self.tlsContext = TLSClient.insecureClient()
            let port = (UInt16(getservbyname(service.cString(using: String.Encoding.ascii)!, nil).pointee.s_port))
            try tlsContext!.connect(host: hostname, port: "\(port.byteSwapped)")
        }
    }
    
    
    public init(tls: Bool = false, hostname: String, port: in_port_t, type: SXSocketTypes = .stream, `protocol`: Int32 = 0, bufsize: Int = SXConnectionSocket.defaultBufsize) throws {
        let addresses: [SXSocketAddress] = try! SXSocketAddress.DNSLookup(hostname: hostname, port: port)
        var fd: Int32 = -1
        self.type = type
        self.domain = .unspec
        self.`protocol` = `protocol`
        self.readBufsize = bufsize
        
        searchAddress: for address in addresses {
            switch address {
            case var .inet(addr):
                fd = socket(AF_INET, type.rawValue, 0)
                if Foundation.connect(fd, pointer(of: &addr).cast(to: sockaddr.self), address.socklen) == -1 {
                    continue
                }
                self.domain = .inet
                break searchAddress
            case var .inet6(addr):
                fd = socket(AF_INET6, type.rawValue, 0)
                if Foundation.connect(fd, pointer(of: &addr).cast(to: sockaddr.self), address.socklen) == -1 {
                    continue
                }
                self.domain = .inet6
                break searchAddress
            default:
                throw SXSocketError.notInetDomain
            }
        }
        
        if fd == -1 {
            throw SXSocketError.unconnectable
        }
        
        self.sockfd = fd
        
        if tls {
            self.tlsContext = TLSClient.insecureClient()
            try tlsContext!.connect(host: hostname, port: "\(port)")
        }
    }
    
    public init(ipv4: String, port: in_port_t, type: SXSocketTypes = .stream, `protocol`: Int32 = 0, bufsize: Int = SXConnectionSocket.defaultBufsize) throws {
        self.sockfd = socket(AF_INET, type.rawValue, `protocol`)
        self.domain = .inet
        self.type = type
        self.protocol = `protocol`
        self.address = SXSocketAddress(address: ipv4, withDomain: .inet, port: port)
        self.readBufsize = bufsize
        switch self.address! {
        case var .inet(addr):
            if Foundation.connect(self.sockfd, pointer(of: &addr).cast(to: sockaddr.self), self.address!.socklen) == -1 {
                throw SXSocketError.connect(String.errno)
            }
        default: throw SXSocketError.nonImplementedDomain
        }
        
    }
    
    public init(tls: Bool = true, ipv6: String, port: in_port_t, type: SXSocketTypes = .stream, `protocol`: Int32 = 0, bufsize: Int = SXConnectionSocket.defaultBufsize) throws {
        self.sockfd = socket(AF_INET6, type.rawValue, `protocol`)
        self.domain = .inet6
        self.type = type
        self.protocol = `protocol`
        self.address = SXSocketAddress(address: ipv6, withDomain: .inet6, port: port)
        self.readBufsize = bufsize
        switch self.address! {
        case var .inet6(addr):
            if Foundation.connect(self.sockfd, pointer(of: &addr).cast(to: sockaddr.self), self.address!.socklen) == -1 {
                throw SXSocketError.connect(String.errno)
            }
        default: throw SXSocketError.nonImplementedDomain
        }
        
    }
    
    public init?(ipv4: String, service: String, type: SXSocketTypes = .stream, `protocol`: Int32 = 0, bufsize: Int = SXConnectionSocket.defaultBufsize) throws {
        let port = (UInt16(getservbyname(service.cString(using: String.Encoding.ascii)!, nil).pointee.s_port)).byteSwapped
        self.sockfd = socket(AF_INET, type.rawValue, `protocol`)
        self.domain = .inet
        self.type = type
        self.protocol = `protocol`
        self.address = SXSocketAddress(address: ipv4, withDomain: .inet, port: port)
        self.readBufsize = bufsize
        switch self.address! {
        case var .inet(addr):
            if Foundation.connect(self.sockfd, pointer(of: &addr).cast(to: sockaddr.self), self.address!.socklen) == -1 {
                throw SXSocketError.connect(String.errno)
            }
        default: throw SXSocketError.nonImplementedDomain
        }
    }
    
    public init(ipv6: String, service: String, type: SXSocketTypes = .stream, `protocol`: Int32 = 0, bufsize: Int = SXConnectionSocket.defaultBufsize) throws {
        let port = (UInt16(getservbyname(service.cString(using: String.Encoding.ascii)!, nil).pointee.s_port)).byteSwapped
        self.sockfd = socket(AF_INET6, type.rawValue, `protocol`)
        self.domain = .inet6
        self.type = type
        self.protocol = `protocol`
        self.address = SXSocketAddress(address: ipv6, withDomain: .inet6, port: port)
        self.readBufsize = bufsize
        switch self.address! {
        case var .inet6(addr):
            if Foundation.connect(self.sockfd, pointer(of: &addr).cast(to: sockaddr.self), self.address!.socklen) == -1 {
                throw SXSocketError.connect(String.errno)
            }
        default: throw SXSocketError.nonImplementedDomain
        }
        
    }
}

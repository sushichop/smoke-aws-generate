// Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//
// main.swift
// SmokeAWSGenerate
//

import Foundation
import ServiceModelCodeGeneration
import ServiceModelEntities
import ServiceModelGenerate
import SmokeAWSModelGenerate

struct CommonConfiguration {
    static let integerDateOverride = RawTypeOverride(typeName: "Double",
                                                     defaultValue: "1.52953091375E9")
    
    static let defaultHttpClientConfiguration = HttpClientConfiguration(
        retryOnUnknownError: true,
        knownErrorsDefaultRetryBehavior: .fail,
        unretriableUnknownErrors: [],
        retriableUnknownErrors: [])
}

var isUsage = CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--help"
let goRepositoryTag = "v1.19.9"

let fileHeader = """
    // Copyright 2018-2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
    //
    // Licensed under the Apache License, Version 2.0 (the "License").
    // You may not use this file except in compliance with the License.
    // A copy of the License is located at
    //
    //     http://www.apache.org/licenses/LICENSE-2.0
    //
    // or in the "license" file accompanying this file. This file is distributed
    // on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
    // express or implied. See the License for the specific language governing
    // permissions and limitations under the License.
    //
    """

// Function to fork a process and get its standard output
func call(arguments: [String], environment: [String: String]? = nil,
          errorHandler: ((Int32, String) -> Data?)? = nil) -> Data {
    let outputPipe = Pipe()
    let errorPipe = Pipe()

    let processEnvironment: [String: String]
    if let environment = environment {
        processEnvironment = ProcessInfo.processInfo.environment.merging(environment) { (_, new) in new }
    } else {
       processEnvironment = ProcessInfo.processInfo.environment
    }
    
    let task = Process()
    task.launchPath = "/usr/bin/env"
    task.environment = processEnvironment
    task.arguments = arguments
    task.standardOutput = outputPipe
    task.standardError = errorPipe
    task.launch()
    task.waitUntilExit()
    
    if task.terminationStatus != 0 {
        let errorData = errorPipe.fileHandleForReading.availableData
        let errorMessage = String(data: errorData, encoding: .utf8) ?? "<none>"
        
        if let errorData = errorHandler?(task.terminationStatus, errorMessage) {
            return errorData
        }
        
        print("Process failed with termination status '\(task.terminationStatus)': '\(errorMessage)'")
        
        exit(-1)
    }

    return outputPipe.fileHandleForReading.availableData
}

func printUsage() {
    let usage = """
        OVERVIEW: Retrieves the current AWS service models and updated the SmokeAWS package.

        USAGE: SmokeAWSGenerate [options]

        OPTIONS:
          --base-file-path     The file path to place the root of the generated Swift package.
        """
    
    print(usage)
}

struct AWSServiceModelDetails {
    let packageName: String
    let baseName: String
}

func getPackageProductEntriesPackageFile(name: String) -> String {
    return """
                    .library(
                        name: "\(name)Client",
                        targets: ["\(name)Client"]),
                    .library(
                        name: "\(name)Model",
                        targets: ["\(name)Model"]),\n
            """
}

func getPackageTargetEntriesPackageFile(name: String) -> String {
    return """
                    .target(
                        name: "\(name)Client",
                        dependencies: ["\(name)Model", "SmokeAWSHttp"]),
                    .target(
                        name: "\(name)Model",
                        dependencies: ["LoggerAPI"]),\n
            """
}

func generatePackageFile(baseNames: [String]) -> String {
    
    var packageFileContents = """
        // swift-tools-version:4.1
        //
        \(fileHeader)
            
        import PackageDescription

        let package = Package(
            name: "SmokeAWS",
            products: [\n
        """
    
    baseNames.forEach { name in
        packageFileContents += getPackageProductEntriesPackageFile(name: name)
    }

    packageFileContents += """
                .library(
                    name: "SmokeAWSCore",
                    targets: ["SmokeAWSCore"]),
                .library(
                    name: "SmokeAWSHttp",
                    targets: ["SmokeAWSHttp"]),
            ],
            dependencies: [
                .package(url: "https://github.com/apple/swift-nio.git", from: "1.8.0"),
                .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "1.0.0"),
                .package(url: "https://github.com/IBM-Swift/LoggerAPI.git", .upToNextMajor(from: "1.0.0")),
                .package(url: "https://github.com/LiveUI/XMLCoding.git", .upToNextMajor(from: "0.4.0")),
                .package(url: "https://github.com/amzn/smoke-http.git", .upToNextMajor(from: "1.0.0")),
            ],
            targets: [\n
        """
    
        baseNames.forEach { name in
        packageFileContents += getPackageTargetEntriesPackageFile(name: name)
    }
    
    packageFileContents += """
                .target(
                    name: "SmokeAWSCore",
                    dependencies: ["LoggerAPI", "XMLCoding"]),
                .target(
                    name: "SmokeAWSHttp",
                    dependencies: ["LoggerAPI", "NIO", "NIOHTTP1", "NIOOpenSSL",
                                   "SmokeAWSCore", "SmokeHTTPClient", "QueryCoding",
                                   "HTTPPathCoding", "HTTPHeadersCoding"]),
                .testTarget(
                    name: "S3ClientTests",
                    dependencies: ["S3Client"]),
                .testTarget(
                    name: "SimpleQueueClientTests",
                    dependencies: ["SimpleQueueClient"]),
                .testTarget(
                    name: "SecurityTokenClientTests",
                    dependencies: ["SecurityTokenClient"]),
                .testTarget(
                    name: "SimpleNotificationClientTests",
                    dependencies: ["SimpleNotificationClient"]),
                .testTarget(
                    name: "ElasticComputeCloudClientTests",
                    dependencies: ["ElasticComputeCloudClient"]),
            ]
        )
        """
    
    return packageFileContents
}

struct ServiceModelDetails {
    let serviceName: String
    let serviceVersion: String
    let baseName: String
    let modelOverride: ModelOverride?
    let httpClientConfiguration: HttpClientConfiguration
    let signAllHeaders: Bool
}

private func generateSmokeAWS(tempDirURL: URL,
                              serviceModelDetails: [ServiceModelDetails],
                              baseFilePath: String) throws {
    let repositoryName = "aws-sdk-go"
    let modelBase = tempDirURL.appendingPathComponent(repositoryName)
    let modelBaseFilePath = String(modelBase.absoluteString.dropFirst(7))
    
    var isDirectory = ObjCBool(true)
    if FileManager.default.fileExists(atPath: modelBaseFilePath, isDirectory: &isDirectory) {
        try FileManager.default.removeItem(at: modelBase)
    }
    
    _ = call(arguments: ["git", "clone", "--branch", goRepositoryTag, "https://github.com/aws/\(repositoryName).git", modelBaseFilePath])
    
    try serviceModelDetails.forEach { (details) in
        let applicationDescription = "The \(details.baseName)Service."
        
        let unrecognizedErrorDeclaration =
            ErrorDeclaration.internal
        
        let customizations = CodeGenerationCustomizations(
            validationErrorDeclaration: .internal,
            unrecognizedErrorDeclaration: unrecognizedErrorDeclaration,
            generateModelShapeConversions: false,
            optionalsInitializeEmpty: true,
            fileHeader: fileHeader,
            httpClientConfiguration: details.httpClientConfiguration)
        
        let modelPath = modelBase.appendingPathComponent("models")
            .appendingPathComponent("apis")
            .appendingPathComponent(details.serviceName)
            .appendingPathComponent(details.serviceVersion)
            .appendingPathComponent("api-2.json")
        let modelFilePath = String(modelPath.absoluteString.dropFirst(7))
        
        let fullApplicationDescription = ApplicationDescription(
            baseName: details.baseName,
            baseFilePath: baseFilePath,
            applicationDescription: applicationDescription,
            applicationSuffix: "Service")
        
        try SmokeAWSModelGenerate.generateFromModel(
            modelFilePath: modelFilePath,
            customizations: customizations,
            applicationDescription: fullApplicationDescription,
            modelOverride: details.modelOverride,
            signAllHeaders: details.signAllHeaders)
    }
    
    try FileManager.default.removeItem(at: modelBase)
    
    try FileManager.default.removeItem(at: tempDirURL)
    
    let baseNames = serviceModelDetails.map { (details) in details.baseName }
        .sorted(by: <)
    let packageFile = generatePackageFile(baseNames: baseNames)
    try packageFile.write(toFile: baseFilePath + "/Package.swift", atomically: false, encoding: String.Encoding.utf8)
}

func createTempDirectory(errorMessage: inout String?) -> URL? {
    let tempDirURL = NSURL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codegen-resources")
    if let tempDirURL = tempDirURL {
        do {
            try FileManager.default.createDirectory(at: tempDirURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            errorMessage = "Unable to create temporary directory."
        }
    } else {
        errorMessage = "Unable to create temporary directory path."
    }
    
    return tempDirURL
}

func handleApplication() throws {
    let baseFilePathOption = "--base-file-path"
    
    let serviceModelDetails: [ServiceModelDetails] = [
        EC2Configuration.serviceModelDetails,
        ECSConfiguration.serviceModelDetails,
        S3Configuration.serviceModelDetails,
        SimpleQueueConfiguration.serviceModelDetails,
        StepFunctionsConfiguration.serviceModelDetails,
        STSConfiguration.serviceModelDetails,
        SNSConfiguration.serviceModelDetails,
        DynamoDBConfiguration.serviceModelDetails,
        SimpleWorkflowConfiguration.serviceModelDetails,
        CloudwatchConfiguration.serviceModelDetails,
        RDSConfiguration.serviceModelDetails]
    
    var baseFilePath: String?
    var missingOptions: Set<String> = [baseFilePathOption]
    
    var currentOption: String?
    var errorMessage: String?
    for argument in CommandLine.arguments.dropFirst() {
        if currentOption == nil && argument.hasPrefix("--") {
            currentOption = argument
            missingOptions.remove(argument)
        } else if let option = currentOption, !argument.hasPrefix("--") {
            switch option {
            case baseFilePathOption:
                baseFilePath = argument
            default:
                errorMessage = "Unrecognized option: \(option)"
            }
            
            currentOption = nil
        } else {
            printUsage()
            
            break
        }
        
    }
    
    let tempDirURL = createTempDirectory(errorMessage: &errorMessage)
    
    if errorMessage == nil {
        if let baseFilePath = baseFilePath,
            let tempDirURL = tempDirURL {
            try generateSmokeAWS(tempDirURL: tempDirURL,
                                 serviceModelDetails: serviceModelDetails,
                                 baseFilePath: baseFilePath)
        } else {
            var missingOptionsString: String = ""
            missingOptions.forEach { option in missingOptionsString += " " + option }
            
            errorMessage = "Missing required options:" + missingOptionsString
        }
    }
    
    if let errorMessage = errorMessage {
        print("ERROR: \(errorMessage)\n")
        
        printUsage()
    }
}

if isUsage {
    printUsage()
} else {
    try handleApplication()
}

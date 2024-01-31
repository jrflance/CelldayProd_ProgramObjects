--liquibase formatted sql

--changeset lizhou:971859 stripComments:false runOnChange:true
CREATE OR ALTER PROC [dbo].[P_LogError_bak]
    (
        @Entity VARCHAR(100),
        @ErrorType VARCHAR(100),
        @ERP_Native_ID INT,
        @VP_Native_ID INT,
        @ErrorCode INT,
        @ErrorMessage VARCHAR(1000)
    )
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    BEGIN TRY
        INSERT INTO cwh.ErrorLog
        (
            Entity,
            ErrorType,
            ERP_Native_ID,
            VP_Native_ID,
            ErrorCode,
            ErrorMessage
        )
        SELECT
            @Entity AS Entity, @ErrorType AS ErrorType, @ERP_Native_ID AS ERP_Native_ID,
            @VP_Native_ID AS VP_Native_ID, @ErrorCode AS ErrorCode, @ErrorMessage AS ErrorMessage;

        SELECT * FROM QEDL.tblTransferStatus WHERE TransferStatusDescription = 'Success'

    END TRY
    BEGIN CATCH
        SELECT
            TransferStatusCode,
            TransferStatusDescription + ' - ' + ERROR_NUMBER() + ' - ' + ERROR_MESSAGE() AS TransferStatusDescription
        FROM QEDL.tblTransferStatus WHERE TransferStatusDescription = 'Fail'
    END CATCH
END

--liquibase formatted sql

--changeset  BrandonStahl:4313f452-1479-4d06-b412-7d6be78b35a4 stripComments:false runOnChange:true splitStatements:false

-- =============================================
-- Author:		Brandon Stahl
-- Create date: 2024-06-19
-- Description: Victra wrapper temp solution until data upload v2 is completed.
-- =============================================
CREATE OR ALTER PROCEDURE [Account].[P_UpsertUsers_VictraWrapper]
    (
        @FileId INT
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        DECLARE
            @Separator VARCHAR(8),
            @TextDelimiter VARCHAR(8) = '"',
            @TopParentAccountId INT = 158286;
        SELECT
            @Separator = ft.Delimiter,
            @TextDelimiter = ft.ROWDelimiter
        FROM upload.tblFileType AS ft
        JOIN upload.tblFile AS f
            ON f.FileTypeID = ft.FileTypeID
        WHERE f.FileID = @FileID;

        TRUNCATE TABLE CellDayTemp.Upload.tblOutPutFile;
        INSERT INTO CellDayTemp.Upload.tblOutPutFile
        (
            Output
        )
        VALUES
        (
            -- noqa: disable=all
            'VidapayUserId,VidapayUserName,SourceUserId,SourceUserName,FirstName,LastName,Email,UserType,LocationId,Change,AccountId,Status,Message'
            -- noqa: enable=all
        );

        DROP TABLE IF EXISTS #final;

        CREATE TABLE #final
        (
            VidapayUserId INT NULL,
            VidapayUserName VARCHAR(100),
            SourceUserId VARCHAR(100) NULL,
            SourceUserName VARCHAR(100) NULL,
            FirstName VARCHAR(100) NULL,
            LastName VARCHAR(100) NULL,
            Email VARCHAR(100) NULL,
            UserType VARCHAR(100) NULL,
            LocationId VARCHAR(100) NULL,
            Change VARCHAR(100) NULL,
            AccountId VARCHAR(100) NULL,
            [Status] VARCHAR(100) NULL,
            [Message] VARCHAR(100) NULL,
        );

        EXECUTE Account.P_UpsertUsers @TopParentAccountId;

        WITH CTEFinal AS (
            SELECT
                CONVERT(
                    VARCHAR(8000),
                    Tracfone.fnEdiRows(
                        @Separator,
                        '',
                        '',
                        VidapayUserId,
                        VidapayUserName,
                        SourceUserId,
                        SourceUserName,
                        FirstName,
                        LastName,
                        Email,
                        UserType,
                        LocationId,
                        Change,
                        AccountId,
                        [Status],
                        -- noqa: disable=all
                        [Message],
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT
                    -- noqa: enable=all
                    )
                ) AS PlainText
            FROM #final AS SUB
        )
        INSERT INTO upload.OutPutFile
        (
            Output
        )
        SELECT PlainText
        FROM CTEFinal AS SUB;


        DROP TABLE #final;
        DECLARE
            @CNT INT =
            (
                SELECT COUNT(1) FROM CellDayTemp.Upload.tblOutPutFile
            );
        --SET @CNT = IIF(@CNT < 2, 2, @CNT);
        SELECT @CNT AS RecordCount;
    END TRY
    BEGIN CATCH
        DECLARE
            @ERRMSG VARCHAR(200) =
            (
                SELECT ERROR_MESSAGE()
            );

        UPDATE f
        SET
            f.FileStatus = -1,
            f.ErrorInfo = @ERRMSG
        FROM upload.tblFile AS f
        WHERE FileID = @FileID

        SELECT 0 AS RecordCount
        ; THROW;
    END CATCH
END;

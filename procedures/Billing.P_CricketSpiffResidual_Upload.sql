--liquibase formatted sql

--changeset melissarios:21310418 stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
/* =============================================
             :
      Author : Melissa Rios
             :
     Created : 2024-04-18
             :
 Description : This SPOC inserts residual records into the Billing tables for
			   : the retro spiffs and residuals if applicable.
			   :	A pipeline delimeted file is uploaded to
			   : CellDayTemp.upload.tblPlainTextFiles. Validation is
			   : done to ensure that the activation order exists, the merchant
			   : account is the correct merchant, that the carrier is the
			   : correct carrier for the process, and the spiff amounts have not already been paid out.
               :
============================================= */
-- noqa: enable=all
CREATE OR ALTER PROC Billing.P_CricketSpiffResidual_Upload
    (@File INT)
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    DECLARE @ErrMsg VARCHAR(512) = '';
    BEGIN TRAN;
    BEGIN TRY


        DECLARE @FileID INT = @File

        DECLARE
            @SecondMonthSpiffProductID INT = (
                SELECT pm.ProductID
                FROM billing.tblBPProductMapping AS pm
                WHERE pm.CarrierID = 56 AND pm.BPProcessTypeID = 1
            ),
            @ThirdMonthSpiffProductID INT = (
                SELECT pm.ProductID
                FROM billing.tblBPProductMapping AS pm
                WHERE pm.CarrierID = 56 AND pm.BPProcessTypeID = 2
            ),
            @ResidualProductID INT = (
                SELECT pm.ProductID
                FROM billing.tblBPProductMapping AS pm
                WHERE pm.CarrierID = 56 AND pm.BPProcessTypeID = 3
            )

        DECLARE
            @Delimiter VARCHAR(16) = (
                SELECT ISNULL(Delimiter, '|')
                FROM billing.tblFileType
                WHERE FileTypeID = 13
            )


        UPDATE Billing.tblFiles
        SET
            Status = 1,
            UploadDate = GETDATE()
        WHERE FileID = @FileID;

        IF OBJECT_ID('tempdb..#ResidualAndSpiffUpload') IS NOT NULL
            BEGIN
                DROP TABLE #ResidualAndSpiffUpload;
            END;

        CREATE TABLE #ResidualAndSpiffUpload
        (
            DetailsID INT,
            ActivationDate DATETIME,
            ActivityDate DATETIME,
            MonthsPaid INT,
            AccountNumber INT,
            MDN VARCHAR(20),
            IMEI VARCHAR(50),
            AmountToPay DECIMAL(9, 2),
            FileNamed VARCHAR(150),
            ActivationOrderNo INT,
            ProductID INT,
            MerchantAccountID INT,
            AccountType VARCHAR(50)
        )

        INSERT INTO #ResidualAndSpiffUpload
        (
            DetailsID,
            ActivationDate,
            ActivityDate,
            MonthsPaid,
            AccountNumber,
            MDN,
            IMEI,
            AmountToPay,
            FileNamed,
            ActivationOrderNo,
            ProductID,
            MerchantAccountID,
            AccountType
        )

        SELECT
            A.Chr1 AS DetailsId,
            A.Chr2 AS ActivationDate,
            A.Chr3 AS ActivityDate,
            A.Chr4 AS MonthsPaid,
            A.Chr5 AS AccountNumber,
            A.Chr6 AS MDN,
            A.Chr7 AS IMEI,
            REPLACE(A.Chr8, '$', '') AS AmountToPayout,
            A.Chr9 AS FileNamed,
            A.Chr10 AS ActivationOrderNo,
            A.Chr11 AS ProductID,
            A.Chr12 AS AccountID,
            REPLACE(
                REPLACE(ISNULL(A.Chr13, ''), CHAR(10), ''), CHAR(13),
                ''
            ) AS AccountType
        FROM Upload.tblPlainTextFiles AS ptf
        CROSS APPLY dbo.SplitText(ptf.Txt, @Delimiter, '"') AS A
        WHERE ptf.FileID = @FileID;

        IF OBJECT_ID('tempdb..#ResidualUploadSummed') IS NOT NULL
            BEGIN
                DROP TABLE #ResidualUploadSummed;
            END;

        SELECT
            r.ActivationOrderNo,
            r.AccountNumber,
            r.MDN,
            r.ActivationDate,
            SUM(r.AmountToPay) AS AmountToPay,
            r.AccountType,
            r.MerchantAccountID
        INTO #ResidualUploadSummed
        FROM #ResidualAndSpiffUpload AS r
        WHERE r.ProductID = @ResidualProductID
        GROUP BY
            r.ActivationOrderNo,
            r.AccountNumber,
            r.MDN,
            r.ActivationDate,
            r.AccountType,
            r.MerchantAccountID

        IF OBJECT_ID('tempdb..#SpiffUploadSummed') IS NOT NULL
            BEGIN
                DROP TABLE #SpiffUploadSummed;
            END;

        SELECT
            r.ActivationOrderNo,
            r.AccountNumber,
            r.MDN,
            r.ActivationDate,
            SUM(r.AmountToPay) AS AmountToPay,
            r.MonthsPaid,
            r.AccountType,
            r.MerchantAccountID
        INTO #SpiffUploadSummed
        FROM #ResidualAndSpiffUpload AS r
        WHERE r.ProductID IN (@SecondMonthSpiffProductID, @ThirdMonthSpiffProductID)
        GROUP BY
            r.ActivationOrderNo,
            r.AccountNumber,
            r.MDN,
            r.ActivationDate,
            r.MonthsPaid,
            r.AccountType,
            r.MerchantAccountID

        IF OBJECT_ID('tempdb..#UploadFile') IS NOT NULL
            BEGIN
                DROP TABLE #UploadFile;
            END;

        CREATE TABLE #UploadFile
        (
            ID INT IDENTITY (1, 1),
            OrderNo INT,
            AmountToPay DECIMAL(9, 2),
            MonthOfSpiff INT,
            MerchantAccountID INT,
            MDN VARCHAR(20),
            CarrierAccountNumber VARCHAR(20),
            TransactionDate DATETIME,
            BPProcessTypeID SMALLINT
        );

        INSERT INTO #UploadFile
        (
            OrderNo,
            AmountToPay,
            MerchantAccountID,
            MDN,
            CarrierAccountNumber,
            TransactionDate,
            BPProcessTypeID
        )

        SELECT
            r.ActivationOrderNo,
            r.AmountToPay,
            r.MerchantAccountID,
            r.MDN,
            r.AccountNumber,
            r.ActivationDate,
            3 AS BPProcessTypeID
        FROM #ResidualUploadSummed AS r
        WHERE r.AccountType = 'Merchant'

        INSERT INTO #UploadFile
        (
            OrderNo,
            AmountToPay,
            MerchantAccountID,
            MDN,
            CarrierAccountNumber,
            TransactionDate,
            BPProcessTypeID
        )
        SELECT
            ISNULL(r.ActivationOrderNo, 0) AS OrderNumber,
            0.00 AS MerchantAmount,
            r.MerchantAccountID,
            r.MDN,
            r.AccountNumber,
            r.ActivationDate,
            3 AS BPProcessTypeID
        FROM #ResidualUploadSummed AS r
        WHERE
            NOT EXISTS (
                SELECT 1 FROM #UploadFile AS u
                WHERE u.MDN = r.MDN
            )
            AND r.AccountType = 'Master'

        INSERT INTO #UploadFile
        (
            OrderNo,
            AmountToPay,
            MonthOfSpiff,
            MerchantAccountID,
            MDN,
            CarrierAccountNumber,
            TransactionDate,
            BPProcessTypeID
        )
        SELECT
            s.ActivationOrderNo,
            s.AmountToPay,
            s.MonthsPaid,
            s.MerchantAccountID,
            s.MDN,
            s.AccountNumber,
            s.ActivationDate,
            CASE
                WHEN s.MonthsPaid = 2 THEN 1
                WHEN s.MonthsPaid = 3 THEN 2
                ELSE 4
            END AS BPProcessTypeID
        FROM #SpiffUploadSummed AS s


        IF OBJECT_ID('tempdb..#BPMappingResidualAndSpiff') IS NOT NULL
            BEGIN
                DROP TABLE #BPMappingResidualAndSpiff;
            END;

        CREATE TABLE #BPMappingResidualAndSpiff
        (
            ID INT,
            BillingPaymentID INT
        );

        MERGE Billing.tblBillingPayments AS bp
        USING
            (
                SELECT
                    s.ID,
                    @FileID AS FileID,
                    s.MerchantAccountID,
                    s.AmountToPay,
                    s.TransactionDate,
                    0 AS BPStatusID,
                    GETDATE() AS StatusUpdated,
                    12 AS ParentCompanyID,
                    s.BPProcessTypeID AS BPProcessTypeID
                FROM #UploadFile AS s

            ) AS vrp
            ON 1 = 0
        WHEN NOT MATCHED BY TARGET
            THEN
            INSERT
                (
                    FileID,
                    AccountID,
                    MerchantAmount,
                    TransactionDate,
                    BPStatusID,
                    StatusUpdated,
                    ParentCompanyID,
                    BPProcessTypeID
                )
            VALUES
                (
                    vrp.FileID, vrp.MerchantAccountID, vrp.AmountToPay, vrp.TransactionDate, vrp.BPStatusID,
                    vrp.StatusUpdated, vrp.ParentCompanyID, vrp.BPProcessTypeID
                )
        OUTPUT
            vrp.ID,
            Inserted.BillingPaymentID
        INTO
            #BPMappingResidualAndSpiff
            (
                ID,
                BillingPaymentID
            );

        IF OBJECT_ID('tempdb..#BPDataInsert') IS NOT NULL
            BEGIN
                DROP TABLE #BPDataInsert;
            END;

        SELECT DISTINCT
            up.BillingPaymentID,
            up.[Data],
            up.DataType
        INTO #BPDataInsert
        FROM
            (
                SELECT
                    bpm.BillingPaymentID,
                    uf.mdn AS MDN,
                    uf.CarrierAccountNumber AS AccountNumber,
                    CAST(uf.OrderNo AS VARCHAR(20)) AS OOrderNo
                FROM #UploadFile AS uf
                JOIN #BPMappingResidualAndSpiff AS bpm
                    ON bpm.ID = uf.ID
                WHERE uf.MDN IS NOT NULL
            ) AS x
        UNPIVOT
        (
            [Data]
            FOR DataType IN (MDN, AccountNumber, OOrderNo)
        ) AS up;

        INSERT INTO Billing.tblBPData
        (
            DataType,
            Data
        )
        SELECT DISTINCT
            di.DataType,
            di.Data
        FROM #BPDataInsert AS di
        WHERE
            NOT EXISTS
            (
                SELECT 1
                FROM Billing.tblBPData AS bd
                WHERE
                    bd.Data = di.Data
                    AND bd.DataType = di.DataType
            );

        INSERT INTO Billing.tblBPDataMapping
        (
            BillingPaymentID,
            BPDataID
        )
        SELECT
            bdi.BillingPaymentID,
            bd.BPDataID
        FROM #BPDataInsert AS bdi
        JOIN Billing.tblBPData AS bd
            ON
                bd.DataType = bdi.DataType
                AND bd.Data = bdi.Data;


        INSERT INTO Billing.tblBPMAAmount
        (
            BillingPaymentID,
            MAAccountId,
            Amount
        )

        SELECT
            bm.BillingPaymentID,
            ISNULL(dbo.fn_GetTopParent_NotTcetra_h(a.Hierarchy), 2) AS MAAccountID,
            s.AmountToPay
        FROM #ResidualUploadSummed AS s
        JOIN #UploadFile AS uf
            ON
                uf.MDN = s.MDN
                AND uf.CarrierAccountNumber = s.AccountNumber
                AND uf.TransactionDate = s.ActivationDate
        JOIN #BPMappingResidualAndSpiff AS bm
            ON bm.ID = uf.ID
        LEFT JOIN dbo.account AS a
            ON a.Account_ID = s.MerchantAccountID
        WHERE s.AccountType = 'Master'


        UPDATE bp
        SET bp.BPStatusID = 3 --Cannot Locate Order
        FROM billing.tblBillingPayments AS bp
        WHERE
            bp.FileID = @FileID
            AND ISNULL(bp.AccountID, 0) = 0


        UPDATE Billing.tblFiles
        SET
            Status = 3,
            UploadDate = GETDATE()
        WHERE FileID = @FileID;

        COMMIT TRAN;

    END TRY
    BEGIN CATCH
        SET @ErrMsg = ERROR_MESSAGE();
        ROLLBACK TRAN;
        UPDATE Billing.tblFiles
        SET
            Status = 4,
            ErrorTxt = @ErrMsg
        WHERE FileID = @FileID;
        RAISERROR (@ErrMsg, 16, 1);
        RETURN;
    END CATCH;
END;

-- noqa: disable=all
/
